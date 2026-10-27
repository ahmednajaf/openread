import os, pathlib
os.environ['TOKENIZERS_PARALLELISM']='false'
os.environ.setdefault('HF_HOME',str(pathlib.Path(os.environ.get('OPENREAD_PRONUNCIATION_WORK','.local/pronunciation-training'))/'hf'))
import csv,json,random,re,time,pathlib,urllib.request
import numpy as np, torch
from transformers import BertModel,BertTokenizerFast,get_linear_schedule_with_warmup
from torch import nn
from torch.utils.data import Dataset,DataLoader
ROOT=pathlib.Path(os.environ.get('OPENREAD_PRONUNCIATION_WORK','.local/pronunciation-training')).resolve();ROOT.mkdir(parents=True,exist_ok=True);BASE=ROOT/'bert-mini';BASE.mkdir(exist_ok=True)
REV='387825ce42dbb39b87911cdf8e383ee3b25184f8'
for name in ['config.json','vocab.txt','pytorch_model.bin','README.md']:
 if not (BASE/name).exists():urllib.request.urlretrieve('https://huggingface.co/google/bert_uncased_L-4_H-256_A-4/resolve/'+REV+'/'+name,BASE/name)
random.seed(41);np.random.seed(41);torch.manual_seed(41);torch.set_num_threads(4)
DEVICE='mps' if torch.backends.mps.is_available() else 'cpu';print('device',DEVICE,flush=True)
DATA=ROOT/'WikipediaHomographData-8f008f021e88f8b71118a27ae655f1f3121162bc'/'data'
wordids=list(csv.DictReader((DATA/'wordids.tsv').open(),delimiter='\t'));classes=sorted(set(r['wordid'] for r in wordids));ids={s:i for i,s in enumerate(classes)}
candidates={}
for r in wordids:candidates.setdefault(r['homograph'],[]).append(ids[r['wordid']])
tokenizer=BertTokenizerFast(vocab_file=str(BASE/'vocab.txt'),do_lower_case=True)
def encode(text,start,end):
 # Preserve target and bounded left/right sentence context, rather than truncate
 # the beginning of the sentence and risk dropping a later target.
 left=tokenizer.encode(text[:start],add_special_tokens=False)[-55:]
 target=tokenizer.encode(text[start:end],add_special_tokens=False)
 right=tokenizer.encode(text[end:],add_special_tokens=False)[:55]
 return [101]+left+[1]+target+[2]+right+[102]
def rows(split):
 result=[]
 for file in sorted((DATA/split).glob('*.tsv')):
  for r in csv.DictReader(file.open(),delimiter='\t'):
   s=r['sentence'];a=len(s.encode()[:int(r['start'])].decode());b=len(s.encode()[:int(r['end'])].decode())
   result.append((encode(s,a,b),ids[r['wordid']],candidates[r['homograph']]))
 return result
alltrain=rows('train');random.shuffle(alltrain);n=int(len(alltrain)*.9);train,dev=alltrain[:n],alltrain[n:];test=rows('eval')
def collate(rows):
 width=max(len(r[0]) for r in rows);x=torch.zeros((len(rows),width),dtype=torch.long);mask=torch.zeros((len(rows),len(classes)))
 for i,(tokens,label,allowed) in enumerate(rows):x[i,:len(tokens)]=torch.tensor(tokens);mask[i,allowed]=1
 return x,(x!=0).long(),torch.tensor([r[1] for r in rows]),mask
class Classifier(nn.Module):
 def __init__(self):
  super().__init__();self.encoder=BertModel.from_pretrained(BASE,attn_implementation='eager');self.drop=nn.Dropout(.1);self.head=nn.Linear(512,len(classes))
 def forward(self,input_ids,attention_mask):
  h=self.encoder(input_ids=input_ids,attention_mask=attention_mask).last_hidden_state
  target=(input_ids==1).float();at=(h*target.unsqueeze(-1)).sum(1)
  return self.head(self.drop(torch.cat((h[:,0],at),dim=-1)))
model=Classifier().to(DEVICE);opt=torch.optim.AdamW(model.parameters(),lr=1e-4,weight_decay=.01)
loader=DataLoader(train,batch_size=32,shuffle=True,collate_fn=collate);epochs=10
scheduler=get_linear_schedule_with_warmup(opt,num_warmup_steps=len(loader),num_training_steps=len(loader)*epochs)
def evaluate(data):
 model.eval();good=total=0
 with torch.no_grad():
  for x,att,y,mask in DataLoader(data,batch_size=64,collate_fn=collate):
   x,att,y,mask=[v.to(DEVICE) for v in [x,att,y,mask]];scores=model(x,att).masked_fill(mask==0,-10000)
   good+=(scores.argmax(-1)==y).sum().item();total+=len(y)
 return good/total
best=0;start=time.monotonic()
for epoch in range(epochs):
 model.train();losses=[]
 for step,(x,att,y,mask) in enumerate(loader):
  x,att,y,mask=[v.to(DEVICE) for v in [x,att,y,mask]];opt.zero_grad();logits=model(x,att).masked_fill(mask==0,-10000);loss=nn.functional.cross_entropy(logits,y);loss.backward();nn.utils.clip_grad_norm_(model.parameters(),1);opt.step();scheduler.step();losses.append(loss.item())
 score=evaluate(dev);print(json.dumps({'epoch':epoch+1,'loss':float(np.mean(losses)),'dev_accuracy':score,'elapsed':time.monotonic()-start}),flush=True)
 if score>best:best=score;torch.save(model.to('cpu').state_dict(),ROOT/'mini-context-best.pt');model.to(DEVICE)
model.load_state_dict(torch.load(ROOT/'mini-context-best.pt',map_location=DEVICE,weights_only=True));final=evaluate(test);print('FINAL HELD OUT',final,flush=True)
(ROOT/'mini-context-metadata.json').write_text(json.dumps({'source_revision':REV,'dataset_revision':'8f008f021e88f8b71118a27ae655f1f3121162bc','classes':classes,'candidates':candidates,'wordids':wordids,'dev_accuracy':best,'test_accuracy':final,'train_count':len(train),'dev_count':len(dev),'test_count':len(test),'seed':41},indent=2))
for s in ['Yesterday, I read the book from cover to cover.','I read the book yesterday.','I read the book every morning.','She had read two chapters before lunch.','Please close the door; the shop is close by.','The wind began to wind around the tower.','The lead pipes were heavy.','They lead the team.','A tear rolled down her cheek.','There was a tear in the letter.','They will record the record tomorrow.']:
 for match in re.finditer(r'\b\w+\b',s):
  if match[0].lower() in candidates:
   x,att,y,mask=collate([(encode(s,*match.span()),0,candidates[match[0].lower()])]);x,att,mask=[v.to(DEVICE) for v in [x,att,mask]]
   with torch.no_grad():p=model(x,att).masked_fill(mask==0,-10000).softmax(-1)[0].cpu()
   print(s,match[0],classes[p.argmax()],float(p.max()),flush=True)
model.to('cpu').eval();x,att,_,_=collate([train[0]]);torch.onnx.export(model,(x,att),str(ROOT/'mini-context.onnx'),input_names=['input_ids','attention_mask'],output_names=['logits'],dynamic_axes={'input_ids':{0:'batch',1:'sequence'},'attention_mask':{0:'batch',1:'sequence'},'logits':{0:'batch'}},opset_version=17,dynamo=False)
from onnxruntime.quantization import quantize_dynamic,QuantType
quantize_dynamic(str(ROOT/'mini-context.onnx'),str(ROOT/'mini-context-int8.onnx'),weight_type=QuantType.QInt8)
print('Export complete',flush=True)
