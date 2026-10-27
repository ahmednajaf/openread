// GPL-3.0-or-later. Keep the original whole-sentence eSpeak pronunciation and
// prosody; replace only confidently aligned, context-selected word groups.
#include "openread_speech.h"
#include <algorithm>
#include <cstdint>
#include <codecvt>
#include <locale>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>
#include <cstdlib>
#include <cstring>
namespace {
std::u32string decode(const std::string& text) { return std::wstring_convert<std::codecvt_utf8<char32_t>, char32_t>().from_bytes(text); }
std::string encode(const std::u32string& text) { return std::wstring_convert<std::codecvt_utf8<char32_t>, char32_t>().to_bytes(text); }
bool space(char32_t c) { return c==32 || (c>=9 && c<=13) || c==0x85 || c==0xa0 || c==0x1680 || (c>=0x2000 && c<=0x200a) || c==0x2028 || c==0x2029 || c==0x202f || c==0x205f || c==0x3000; }
bool sound(char32_t c) { return (c>=U'a' && c<=U'z') || (c>=U'A' && c<=U'Z') || (c>=0x250 && c<=0x2af) || (c>=0x1d00 && c<=0x1dbf); }
bool punctuation(char32_t c) { return std::u32string(U";:,.!?\"'“”‘’()[]{}«»—…").find(c)!=std::u32string::npos; }
std::vector<std::u32string> words(const std::u32string& text) {
 std::vector<std::u32string> result;size_t start=0;
 for(size_t i=0;i<=text.size();++i)if(i==text.size() || space(text[i])){if(i>start)result.push_back(text.substr(start,i-start));start=i+1;}
 return result;
}
std::string phonemes(const char* root,const std::string& text) {
 char* p=openread_speech_phonemize(root,text.c_str());if(!p)throw std::runtime_error("Pronunciation unavailable");std::string result(p);openread_speech_free(p);return result;
}
char* copy(const std::string& text) { auto* p=static_cast<char*>(std::malloc(text.size()+1));if(p)std::memcpy(p,text.c_str(),text.size()+1);return p; }
}
extern "C" char* openread_speech_phonemize_context(const char* root,const char* text,const char* replacements) {
 try {
  if(!root || !text || !replacements || std::strlen(text)>16000 || std::strlen(replacements)>32000)return nullptr;
  const std::string original=phonemes(root,text);
  std::map<int,std::u32string> overrides;std::istringstream lines(replacements);std::string line;
  while(std::getline(lines,line)) { auto tab=line.find('\t');if(tab==std::string::npos)continue;int index=std::stoi(line.substr(0,tab));auto ipa=decode(line.substr(tab+1));if(index>=0 && ipa.size()>0 && ipa.size()<100 && ipa.find_first_of(U"\r\n\t[]<>")==std::u32string::npos)overrides[index]=ipa; }
  if(overrides.empty())return copy(original);
  auto source=words(decode(text));auto actual=decode(original);
  if(source.size()>256)return copy(original);
  std::u32string expected,heard;std::vector<int> owners,positions,groupOf;std::vector<std::pair<int,int>> groups;
  for(size_t i=0;i<source.size();++i)for(auto c:decode(phonemes(root,encode(source[i]))))if(sound(c)){expected+=c;owners.push_back(static_cast<int>(i));}
  int start=0;
  for(size_t i=0;i<=actual.size();++i)if(i==actual.size() || space(actual[i])){if(static_cast<int>(i)>start){int g=groups.size();groups.emplace_back(start,i);for(int j=start;j<static_cast<int>(i);++j)if(sound(actual[j])){heard+=actual[j];positions.push_back(j);groupOf.push_back(g);}}start=i+1;}
  if(expected.size()>2048 || heard.size()>2048)return copy(original);
  const size_t width=heard.size()+1;std::vector<uint16_t> dp((expected.size()+1)*width);
  for(int i=static_cast<int>(expected.size())-1;i>=0;--i)for(int j=static_cast<int>(heard.size())-1;j>=0;--j)
   dp[i*width+j]=expected[i]==heard[j]?1+dp[(i+1)*width+j+1]:std::max(dp[(i+1)*width+j],dp[i*width+j+1]);
  std::vector<int> assigned(heard.size(),-1);size_t i=0,j=0;
  while(i<expected.size() && j<heard.size()) { if(expected[i]==heard[j]){assigned[j]=owners[i];++i;++j;}else if(dp[(i+1)*width+j]>=dp[i*width+j+1])++i;else ++j; }
  struct Change {int a,b;std::u32string ipa;};std::vector<Change> changes;
  for(size_t g=0;g<groups.size();++g){std::vector<size_t> sounds;std::set<int> mapped;
   for(size_t k=0;k<heard.size();++k)if(groupOf[k]==static_cast<int>(g)){sounds.push_back(k);if(assigned[k]>=0)mapped.insert(assigned[k]);}
   if(sounds.size()<2 || mapped.size()!=1)continue;int owner=*mapped.begin();auto found=overrides.find(owner);
   if(found==overrides.end() || assigned[sounds.front()]!=owner || assigned[sounds.back()]!=owner)continue;
   int a=groups[g].first,b=groups[g].second;while(a<b && punctuation(actual[a]))++a;while(b>a && punctuation(actual[b-1]))--b;
   changes.push_back({a,b,found->second});
  }
  for(auto it=changes.rbegin();it!=changes.rend();++it)actual.replace(it->a,it->b-it->a,it->ipa);
  return copy(encode(actual));
 }catch(...){return nullptr;}
}
