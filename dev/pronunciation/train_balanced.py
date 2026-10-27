from pathlib import Path
prefix=(Path(__file__).parent/'train_mini.py').read_text().split("model=Classifier().to(DEVICE)")[0]
exec(compile(prefix,__file__,'exec'))
from collections import Counter
# Grammar data is independent of individual homograph spellings. Supervise the
# same contextual encoder on Penn Treebank tags supplied by UD English EWT.
def grammar_rows(path):
 result=[];tokens=[]
 def flush():
  if not tokens:return
  text=' '.join(w for w,t in tokens);starts=[];n=0
  for w,t in tokens:starts.append(n);n+=len(w)+1
  chosen=[i for i,(w,t) in enumerate(tokens) if w.lower() in candidates]
  others=[i for i,(w,t) in enumerate(tokens) if t.startswith(('VB','NN','JJ','RB')) and i not in chosen]
  random.shuffle(others);chosen+=others[:max(0,4-len(chosen))]
  for i in chosen:result.append((encode(text,starts[i],starts[i]+len(tokens[i][0])),tokens[i][1]))
 for line in path.read_text().splitlines()+['']:
  if not line.strip():flush();tokens=[];continue
  if line.startswith('#'):continue
  parts=line.split('\t')
  if parts[0].isdigit() and parts[4]!='_':tokens.append((parts[1],parts[4]))
 return result
udtrain=grammar_rows(ROOT/'ud-en_ewt-ud-train.conllu');uddev=grammar_rows(ROOT/'ud-en_ewt-ud-dev.conllu')
tags=sorted(set(tag for _,tag in udtrain+uddev));tagids={tag:i for i,tag in enumerate(tags)}
udtrain=[(x,tagids[y]) for x,y in udtrain];uddev=[(x,tagids[y]) for x,y in uddev]
class Joint(Classifier):
 def __init__(self):super().__init__();self.grammar=nn.Linear(512,len(tags))
 def forward(self,input_ids,attention_mask):
  h=self.encoder(input_ids=input_ids,attention_mask=attention_mask).last_hidden_state
  at=(h*(input_ids==1).float().unsqueeze(-1)).sum(1);features=self.drop(torch.cat((h[:,0],at),dim=-1))
  return self.head(features),self.grammar(features)
model=Joint();weights=torch.load(ROOT/'joint-context-best.pt',map_location='cpu',weights_only=True);model.load_state_dict(weights,strict=False);model.to(DEVICE)
# Derive grammatical categories from upstream annotation descriptions. There
# are no word-specific tense or spelling rules.
def allowed_tags(row):
 label=row['label'];parts=set(re.findall(r'[a-z]+',label))
 if 'past tense' in label:return ['VBD','VBN']
 if 'present tense' in label:return ['VB','VBP','VBZ']
 allowed=[]
 if 'verb' in parts:allowed+=['VB','VBD','VBG','VBN','VBP','VBZ']
 if 'noun' in parts:allowed+=['NN','NNS','NNP','NNPS']
 if 'adjective' in parts:allowed+=['JJ','JJR','JJS']
 if 'adverb' in parts:allowed+=['RB','RBR','RBS']
 return sorted(set(allowed))
attributes={ids[r['wordid']]:allowed_tags(r) for r in wordids}
# Only apply grammar when every candidate is described grammatically.
# Lexical senses such as musical/fish bass still rely on sentence semantics.
def final_scores(logits,grammar,mask):
 values=logits.masked_fill(mask==0,-10000)
 gp=grammar.softmax(-1)
 for i in range(len(values)):
  allowed=torch.where(mask[i]>0)[0].tolist()
  if all(attributes.get(j) for j in allowed):
   for j in allowed:
    indices=[tagids[t] for t in attributes[j] if t in tagids]
    prior=gp[i,indices].sum().clamp(min=.01)
    values[i,j]+=prior.log()
 return values
opt=torch.optim.AdamW(model.parameters(),lr=1e-5,weight_decay=.01)
random.shuffle(udtrain); udtrain=udtrain[:12000]
counts=Counter(y for _,y,_ in train)
classweights=torch.tensor([1/(max(1,counts[i])**.5) for i in range(len(classes))],device=DEVICE)
classweights/=classweights.mean()
trainmix=[(x,y,a,0) for x,y,a in train]+[(x,y,[],1) for x,y in udtrain]
def joint_collate(rows):
 width=max(len(r[0]) for r in rows);x=torch.zeros((len(rows),width),dtype=torch.long);mask=torch.zeros((len(rows),len(classes)))
 for i,(tokens,label,allowed,task) in enumerate(rows):x[i,:len(tokens)]=torch.tensor(tokens);mask[i,allowed]=1
 return x,(x!=0).long(),torch.tensor([r[1] for r in rows]),mask,torch.tensor([r[3] for r in rows])
loader=DataLoader(trainmix,batch_size=32,shuffle=True,collate_fn=joint_collate);epochs=3
scheduler=get_linear_schedule_with_warmup(opt,num_warmup_steps=100,num_training_steps=len(loader)*epochs)
def evaluate(data):
 model.eval();good=total=0
 with torch.no_grad():
  for x,att,y,mask in DataLoader(data,batch_size=64,collate_fn=collate):
   x,att,y,mask=[v.to(DEVICE) for v in [x,att,y,mask]];logits,g=model(x,att);scores=final_scores(logits,g,mask)
   good+=(scores.argmax(-1)==y).sum().item();total+=len(y)
 return good/total
best=0;start=time.monotonic();print('joint examples',len(trainmix),'grammar',len(udtrain),flush=True)
for epoch in range(epochs):
 model.train();losses=[]
 for step,(x,att,y,mask,task) in enumerate(loader):
  x,att,y,mask,task=[v.to(DEVICE) for v in [x,att,y,mask,task]];opt.zero_grad();s,g=model(x,att);loss=0
  a=task==0;b=task==1
  if a.any():loss=loss+nn.functional.cross_entropy(s[a].masked_fill(mask[a]==0,-10000),y[a],weight=classweights)
  if b.any():loss=loss+.5*nn.functional.cross_entropy(g[b],y[b])
  loss.backward();nn.utils.clip_grad_norm_(model.parameters(),1);opt.step();scheduler.step();losses.append(loss.item())
 score=evaluate(dev);print(json.dumps({'epoch':epoch+1,'loss':float(np.mean(losses)),'dev_accuracy':score,'elapsed':time.monotonic()-start}),flush=True)
 if score>best:best=score;torch.save(model.to('cpu').state_dict(),ROOT/'balanced-context-best.pt');model.to(DEVICE)
model.load_state_dict(torch.load(ROOT/'balanced-context-best.pt',map_location=DEVICE,weights_only=True));final=evaluate(test);print('FINAL HELD OUT',final,flush=True)
metadata=json.loads((ROOT/'mini-context-metadata.json').read_text());metadata.update({'tags':tags,'grammar_attributes':{classes[k]:v for k,v in attributes.items()},'dev_accuracy':best,'test_accuracy':final,'grammar_train_count':len(udtrain),'grammar_dataset_revision':(ROOT/'ud-revision.txt').read_text().strip()});(ROOT/'balanced-context-metadata.json').write_text(json.dumps(metadata,indent=2))
for s in ['Yesterday, I read the book from cover to cover.','I read the book yesterday.','I read the book every morning.','She had read two chapters before lunch.','Please close the door; the shop is close by.','The wind began to wind around the tower.','The lead pipes were heavy.','They lead the team.','A tear rolled down her cheek.','There was a tear in the letter.','They will record the record tomorrow.']:
 for match in re.finditer(r'\b\w+\b',s):
  if match[0].lower() in candidates:
   x,att,y,mask=collate([(encode(s,*match.span()),0,candidates[match[0].lower()])]);x,att,mask=[v.to(DEVICE) for v in [x,att,mask]]
   with torch.no_grad():logits,g=model(x,att);p=final_scores(logits,g,mask).softmax(-1)[0].cpu();gp=g.softmax(-1)[0].cpu()
   print(s,match[0],classes[p.argmax()],float(p.max()),tags[gp.argmax()],float(gp.max()),flush=True)
model.to('cpu').eval();x,att,_,_=collate([train[0]]);torch.onnx.export(model,(x,att),str(ROOT/'balanced-context.onnx'),input_names=['input_ids','attention_mask'],output_names=['logits','grammar'],dynamic_axes={'input_ids':{0:'batch',1:'sequence'},'attention_mask':{0:'batch',1:'sequence'},'logits':{0:'batch'},'grammar':{0:'batch'}},opset_version=17,dynamo=False)
from onnxruntime.quantization import quantize_dynamic,QuantType
quantize_dynamic(str(ROOT/'balanced-context.onnx'),str(ROOT/'balanced-context-int8.onnx'),weight_type=QuantType.QInt8)
print('Export complete',flush=True)
