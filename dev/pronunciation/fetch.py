"""Download pinned public training inputs. Run inside an isolated Python environment."""
from pathlib import Path
import io, os, urllib.request, zipfile
ROOT=Path(os.environ.get('OPENREAD_PRONUNCIATION_WORK',Path.cwd()/'.local/pronunciation-training')).resolve()
ROOT.mkdir(parents=True,exist_ok=True)
def get(url,path):
 if not path.exists():
  with urllib.request.urlopen(url) as response:path.write_bytes(response.read())
wiki='8f008f021e88f8b71118a27ae655f1f3121162bc'
archive=ROOT/'wiki.zip';get(f'https://codeload.github.com/google-research-datasets/WikipediaHomographData/zip/{wiki}',archive)
with zipfile.ZipFile(archive) as z:
 for name in z.namelist():
  path=ROOT/name
  if not path.resolve().is_relative_to(ROOT):raise ValueError('Invalid archive path')
 z.extractall(ROOT)
ud='c5baffde1e106bcd828c520109eb905bfc3ac06f'
for source,name in [('en_ewt-ud-train.conllu','ud-en_ewt-ud-train.conllu'),('en_ewt-ud-dev.conllu','ud-en_ewt-ud-dev.conllu'),('LICENSE.txt','ud-LICENSE.txt'),('README.md','ud-README.md')]:get(f'https://raw.githubusercontent.com/UniversalDependencies/UD_English-EWT/{ud}/{source}',ROOT/name)
(ROOT/'ud-revision.txt').write_text(ud+'\n')
print(ROOT)
