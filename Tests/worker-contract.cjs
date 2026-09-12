// Runs the supplied Worker against an isolated fake DB and fake external APIs.
// No live credentials, network writes or production saves are used.
const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const crypto=require('node:crypto').webcrypto;
const sourcePath=process.argv[2];
if(!sourcePath)throw Error('Usage: node worker-contract.cjs path/to/worker/src/index.js');
const requests=[],writes=[];
const env={APP_TOKEN:'test-only-master',LOG_TOKEN_SECRET:'test-only-secret',DEEPL_API_KEY:'test-only-key',GROQ_API_KEY:'test-only-groq',DB:{prepare(sql){return {values:[],bind(...values){this.values=values;return this},async first(){return {id:'session-1',title:'Test session'}},async run(){writes.push({sql,values:this.values});return {}},async all(){return {results:[]}}}}}};
const context=vm.createContext({crypto,Request,Response,Headers,URL,URLSearchParams,TextEncoder,TextDecoder,btoa,atob,console,AbortSignal,
fetch:async(url,options)=>{requests.push({url,options});if(String(url).includes('deepl.com'))return Response.json({translations:[{text:'테스트 번역'}]});
if(String(url).includes('groq.com'))return Response.json({choices:[{finish_reason:'stop',message:{content:JSON.stringify({translation:'안녕',units:[{surface:'こんにちは',lemma:'こんにちは',reading:'こんにちは',meaning:'안녕',note:'',kind:'word'}]})}}]});
throw Error('Unexpected external request: '+url)}});
vm.runInContext(fs.readFileSync(sourcePath,'utf8').replace('export default {','globalThis.worker = {'),context);
const call=(p,body,token,master=false)=>context.worker.fetch(new Request('https://test.invalid'+p,{method:body?'POST':'GET',headers:{'content-type':'application/json',...(token?{[master?'x-app-token':'x-log-token']:token}:{})},body:body?JSON.stringify(body):undefined}),env);
let passed=0;
const test=async(name,fn)=>{await fn();passed++;console.log('PASS '+name)};
(async()=>{
 let token;
 await test('unauthenticated issuance rejects (existing dispatcher does not await)',async()=>assert.rejects(call('/auth/open-token',{}),e=>e.status===401));
 await test('existing APP_TOKEN issues 24h log token',async()=>{const r=await call('/auth/open-token',{},env.APP_TOKEN,true);assert.equal(r.status,200);const j=await r.json();assert.equal(j.expires_in,86400);token=j.log_token;assert.ok(token)});
 await test('Japanese lemma goes to existing DeepL endpoint',async()=>{const r=await call('/run/translate',{text:'走る',src:'JA',tgt:'KO'},token);assert.equal(r.status,200);const body=requests.at(-1).options.body;assert.equal(body.get('source_lang'),'JA');assert.equal(body.get('text'),'走る')});
 await test('English popup translation uses EN',async()=>{assert.equal((await call('/run/translate',{text:'run',src:'EN',tgt:'KO'},token)).status,200);assert.equal(requests.at(-1).options.body.get('source_lang'),'EN')});
 await test('no image or bbox required for sentence save',async()=>{const r=await call('/api/save',{session_id:'session-1',source_text:'昨日',context_group_id:'stt:run:chunk',item_type:'sentence_box'},token);assert.equal(r.status,200);assert.equal((await r.json()).media,null)});
 await test('word ranges and explicit group retained',async()=>{const r=await call('/api/save',{session_id:'session-1',source_text:'🎮昨日',item_type:'kanji_box',target_word:'昨日',target_surface:'昨日',target_word_lemma:'昨日',target_word_reading:'きのう',target_start_index:2,target_end_index:4,context_group_id:'stt:run:chunk'},token);assert.equal(r.status,200);const w=writes.filter(x=>/INSERT INTO saved_items/.test(x.sql)).at(-1);assert.equal(w.values[9],2);assert.equal(w.values[10],4);assert.equal(w.values[16],'stt:run:chunk')});
 await test('missing word rejects at handler',async()=>assert.rejects(call('/api/save',{session_id:'session-1',source_text:'昨日',item_type:'kanji_box'},token),e=>e.status===400));
 await test('tampered log token rejects at handler',async()=>assert.rejects(call('/api/sessions/recent',null,token+'invalid'),e=>e.status===401));
 await test('expired token rejects at handler',async()=>{const expired=await context.createLogToken(env,{exp:1});await assert.rejects(call('/api/sessions/recent',null,expired),e=>e.status===401)});
 await test('AI restructure shares existing route and emits UTF16 ranges',async()=>{const r=await call('/run/restructure',{text:'こんにちは',deepl_translation:'안녕',morphs:[]},token);assert.equal(r.status,200);const j=await r.json();assert.equal(j.units[0].start,0);assert.equal(j.units[0].end,5);assert.equal(j.units.map(t=>t.surface).join(''),'こんにちは')});
 console.log(JSON.stringify({passed,liveRequests:0,productionWrites:0}));
})().catch(error=>{console.error(error);process.exitCode=1});
