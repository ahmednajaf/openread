import os,json, math, re, csv, random, hashlib, pathlib, numpy as np, onnxruntime as ort
from transformers import BertTokenizerFast
ROOT=pathlib.Path(os.environ.get('OPENREAD_PRONUNCIATION_WORK','.local/pronunciation-training')).resolve()
meta=json.loads((ROOT/'balanced-context-metadata.json').read_text()); tags=meta['tags']; classes=meta['classes']
tok=BertTokenizerFast(vocab_file=str(ROOT/'bert-mini/vocab.txt'),do_lower_case=True)
lex={}
def allowed_tags(label):
 if 'past tense' in label:return ['VBD','VBN']
 if 'present tense' in label:return ['VB','VBP','VBZ']
 parts=set(re.findall(r'[a-z]+',label));result=[]
 for word,values in [('verb',['VB','VBD','VBG','VBN','VBP','VBZ']),('noun',['NN','NNS','NNP','NNPS']),('adjective',['JJ','JJR','JJS']),('adverb',['RB','RBR','RBS'])]:
  if word in parts:result+=values
 return sorted(set(result))
for r in meta['wordids']:
 ipa=r['pronunciation'].replace("'",'ˈ') if 'pronunciation' in r else r.get('ipa','').replace("'",'ˈ')
 if not ipa or any(c.isdigit() or c in '\t\n\r[]<>' for c in ipa):ipa=None
 lex.setdefault(r['homograph'],[]).append({'id':classes.index(r['wordid']),'ipa':ipa,'description':r['label'],'tags':[tags.index(t) for t in allowed_tags(r['label']) if t in tags]})
print('SAMPLE',list(lex.items())[:2],flush=True)
DATA=ROOT/('WikipediaHomographData-'+meta['dataset_revision'])/'data'
def encode(s,a,b): return [101]+tok.encode(s[:a],add_special_tokens=False)[-55:]+[1]+tok.encode(s[a:b],add_special_tokens=False)+[2]+tok.encode(s[b:],add_special_tokens=False)[:55]+[102]
def rows(split):
 out=[]
 for f in sorted((DATA/split).glob('*.tsv')):
  for r in csv.DictReader(f.open(),delimiter='\t'):
   s=r['sentence'];a=len(s.encode()[:int(r['start'])].decode());b=len(s.encode()[:int(r['end'])].decode());out.append((encode(s,a,b),classes.index(r['wordid']),r['homograph']))
 return out
alltrain=rows('train');random.Random(41).shuffle(alltrain);dev=alltrain[int(len(alltrain)*.9):];test=rows('eval')
opt=ort.SessionOptions();opt.intra_op_num_threads=4;ort.disable_telemetry_events();sess=ort.InferenceSession(str(ROOT/'balanced-context-int8.onnx'),opt,providers=['CPUExecutionProvider'])
def predict(rows):
 out=[]
 for start in range(0,len(rows),32):
  batch=rows[start:start+32];width=max(len(r[0]) for r in batch);ids=np.zeros((len(batch),width),np.int64)
  for i,r in enumerate(batch):ids[i,:len(r[0])]=r[0]
  scores,grammar=sess.run(None,{'input_ids':ids,'attention_mask':(ids!=0).astype(np.int64)})
  for (_,gold,word),s,g in zip(batch,scores,grammar):
   entries=lex[word];values=np.asarray([s[e['id']] for e in entries],np.float64);gp=np.exp(g.astype(np.float64)-max(g));gp/=gp.sum();mass=np.ones(len(entries))
   if all(e['tags'] for e in entries):
    mass=np.asarray([sum(gp[t] for t in e['tags']) for e in entries]);values+=np.log(np.maximum(.01,mass))
   p=np.exp(values-max(values));p/=p.sum();k=int(p.argmax());out.append((entries[k]['id']==gold,float(p[k]),float(mass[k]),entries[k]['ipa'] is not None))
 return out
devp=predict(dev);testp=predict(test)
def report(p,confidence,grammar):
 chosen=[v for v in p if v[1]>=confidence and v[2]>=grammar and v[3]]
 return {'count':len(p),'accepted':len(chosen),'coverage':len(chosen)/len(p),'accepted_accuracy':sum(v[0] for v in chosen)/max(1,len(chosen)),'overall_accuracy':sum(v[0] for v in p)/len(p)}
# Select on development data only, preferring greater coverage subject to 99.0% precision.
trials=[(c,g,report(devp,c,g)) for c in [.99,.995,.997,.999,.9995] for g in [.9,.95,.98]]
print('CALIBRATION',json.dumps(trials),flush=True)
qualified=[r for r in trials if r[2]['accepted_accuracy']>=.99]
best=max(qualified,key=lambda r:r[2]['coverage']) if qualified else max(trials,key=lambda r:r[2]['accepted_accuracy'])
c,g,d=best
# Independent grammatical confidence is always required: joint normalization must not inflate it.
result={'confidence':c,'grammar_confidence':g,'words':lex}
(ROOT/'lexicon.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
reportdata={'base_revision':meta['source_revision'],'dataset_revision':meta['dataset_revision'],'grammar_dataset_revision':meta['grammar_dataset_revision'],'seed':41,'train_count':meta['train_count'],'grammar_train_count':meta['grammar_train_count'],'dev':d,'test':report(testp,c,g),'thresholds':{'sense':c,'grammar':g},'calibration':'Choose highest coverage with >=99.0% accepted development accuracy; test set is never used to select thresholds. Abstentions retain the original frontend.','runtime':'onnxruntime 1.24.2 CPU, dynamic int8','licence':'CC-BY-SA-4.0; upstream Apache-2.0 notices retained'}
(ROOT/'evaluation.json').write_text(json.dumps(reportdata,indent=2)+'\n');print(json.dumps(reportdata,indent=2),flush=True)
