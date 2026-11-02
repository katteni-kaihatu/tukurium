import {spawn} from 'node:child_process';
import {createServer,createConnection} from 'node:net';
import {mkdirSync,readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
const root=resolve(import.meta.dirname,'..'),children=[],session=`vr-${randomUUID()}`;
const work=resolve(root,'.run',session);mkdirSync(work,{recursive:true});
function start(file,args){const c=spawn(resolve(root,file),args,{cwd:root,windowsHide:true,stdio:['ignore','pipe','pipe']});c.logs='';c.stdout.on('data',d=>c.logs+=d);c.stderr.on('data',d=>c.logs+=d);children.push(c);return c;}
async function port(){const s=createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const n=s.address().port;await new Promise(r=>s.close(r));return n;}
const ui=await port(),transport=await port();let observer;
try {
  const engine=start('target/release/kokoverse-engine.exe',['--role','host','--port',String(ui),'--transport-port',String(transport),'--session',session,'--save',resolve(work,'world.json')]);
  for(let i=0;i<100;i++){const s=createConnection({host:'127.0.0.1',port:ui});if(await new Promise(r=>{s.once('connect',()=>r(true));s.once('error',()=>r(false));})){observer=s;break;}s.destroy();await delay(50);}
  assert.ok(observer,'Engine not ready');
  let buffer=Buffer.alloc(0);const messages=[];
  observer.on('data',d=>{buffer=Buffer.concat([buffer,d]);while(buffer.length>=4&&buffer.length>=4+buffer.readUInt32BE()){const n=buffer.readUInt32BE();messages.push(JSON.parse(buffer.subarray(4,n+4)).body);buffer=buffer.subarray(n+4);}});
  const godot=start('.tools/godot/Godot_v4.7.2-stable_win64_console.exe',[...(process.argv.includes('--rendered')?['--rendering-method','gl_compatibility']:['--headless']),'--xr-mode','off','--path','client-godot','--script','res://vr_smoke.gd','--',`--port=${ui}`,`--session=${session}`,`--vr-smoke-report=${resolve(work,'child-pass')}`]);
  const end=Date.now()+90000;while(godot.exitCode===null&&Date.now()<end)await delay(25);
  assert.equal(godot.exitCode,0,godot.logs);assert.doesNotMatch(godot.logs,/SCRIPT ERROR:|\bERROR:/);assert.match(godot.logs,/VR SWITCH SMOKE PASS/);
  assert.equal(engine.exitCode,null,'Engine exited during VR switching');
  assert.match(readFileSync(resolve(work,'child-pass'),'utf8'),/VR movement/);
  for(const m of messages.filter(m=>m.kind==='snapshot'))assert.equal(m.snapshot.world_revision,'0','Switch mutated persistent world');
  const identities=new Set(messages.filter(m=>m.kind==='presence').flatMap(m=>m.participants.map(p=>p.id)));
  assert.ok(identities.size<=1,'Switch created another participant');
  console.log('PASS: rendered buttons, simulated XR movement through Rust, focus/neutral, offset snap turn, ray menu, failure, cancel, reentry, child crash; same Engine/session/participant');
}catch(error){for(const c of children)if(c.logs)console.error(c.logs.slice(-6000));throw error;}
finally{observer?.destroy();for(const c of children)if(c.exitCode===null)c.kill();}
