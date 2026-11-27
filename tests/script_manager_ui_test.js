// Exercise the complete UI script with a small DOM harness, without a browser or dependencies.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ids = new Map();
class Element {
  constructor(tag) { this.tagName=tag;this.children=[];this.value='';this.disabled=false;this.validation=''; }
  set id(value) { this._id=value;ids.set(value,this); }
  get id() { return this._id; }
  append(...items) { this.children.push(...items); }
  replaceChildren(...items) { this.children=items; }
  setAttribute() {}
  setCustomValidity(message) { this.validation=message; }
  reportValidity() { return all(this).every(e=>!e.validation); }
}
function all(element) { return [element,...element.children.flatMap(child=>typeof child==='object'?all(child):[])]; }
for(const id of ['navigation','content','notice','reset','save','register']){const e=new Element('div');e.id=id;}
const messages=[];
const context=vm.createContext({ document:{createElement:tag=>new Element(tag),getElementById:id=>ids.get(id)},window:{webkit:{messageHandlers:{scriptManager:{postMessage:body=>messages.push(JSON.parse(JSON.stringify(body)))}}}},console });
const html=fs.readFileSync('modules/script_manager.html','utf8');
vm.runInContext(html.split('<script>')[1].split('</script>')[0],context);
assert.equal(messages[0].action,'ready');
const modules=[{id:'blink_reminder',title:'休息提醒',description:'提醒休息',enabled:true,running:true,options:{intervalMinutes:30,snoozeMinutes:[5,10]},defaults:{enabled:false,options:{intervalMinutes:20,snoozeMinutes:[1]}}},{id:'browser_dispatcher',title:'浏览器分流',description:'打开网址',enabled:true,running:true,options:{rules:[]},defaults:{enabled:true,options:{rules:[]}}}];
const receive=payload=>context.window.receiveState(JSON.parse(JSON.stringify(payload)));
receive({modules});
assert.equal(ids.get('navigation').children.length,2);
const field=all(ids.get('content')).find(e=>e.tagName==='input'&&e.type==='number'&&e.value===30);
field.value='15';field.oninput();
ids.get('save').onclick();
assert.equal(messages.at(-1).options.intervalMinutes,15);
assert.equal(messages.at(-1).action,'save');
const count=messages.length;ids.get('save').onclick();assert.equal(messages.length,count,'duplicate saves must be blocked');
receive({modules,success:false,message:'配置无效'});
assert.equal(ids.get('notice').textContent,'配置无效');
ids.get('save').onclick();assert.equal(messages.at(-1).options.intervalMinutes,15,'failed apply must retain edits');
modules[0].options.intervalMinutes=15;
receive({modules,savedID:'blink_reminder',success:true,message:'已保存'});
ids.get('reset').onclick();assert.equal(messages.length,count+1,'reset must wait for save');
ids.get('save').onclick();assert.equal(messages.at(-1).enabled,false);assert.equal(messages.at(-1).options.intervalMinutes,20);
receive({modules,savedID:'blink_reminder'});
ids.get('navigation').children[1].onclick();
const addRule=all(ids.get('content')).find(e=>e.tagName==='button'&&e.textContent==='＋ 添加一项');
addRule.onclick();
ids.get('save').onclick();
assert.equal(messages.at(-1).options.rules[0].urls,'example.com');
assert.equal(messages.at(-1).options.rules[0].profile,'choose');
receive({modules,savedID:'browser_dispatcher'});
// Empty Lua tables may be encoded as [], but root options must remain an editable group.
receive({modules:[{id:'empty',title:'空配置',enabled:false,running:false,options:[],defaults:{enabled:false,options:[]}}]});
assert(all(ids.get('content')).some(e=>e.textContent==='＋ 添加设置'));
// Generic settings must not show input-method-specific prompts.
assert(all(ids.get('content')).some(e=>e.placeholder==='设置名称'));
assert(!all(ids.get('content')).some(e=>e.placeholder?.includes('输入法')));
receive({modules:[{id:'input_assistant',title:'输入助手',enabled:true,running:true,options:{appInputSources:{'com.apple.keylayout.ABC':['com.apple.Terminal']}},defaults:{enabled:true,options:{}}}]});
assert(all(ids.get('content')).some(e=>e.placeholder==='输入法 ID'));
assert(all(ids.get('content')).some(e=>e.placeholder==='设置名称'));
// Register a new script, retain its draft on failure, and select it after success.
ids.get('register').onclick();
let fields=all(ids.get('content')).filter(e=>e.tagName==='input'&&e.type==='text');
fields[0].value='my_script';fields[0].oninput();fields[1].value='我的脚本';fields[1].oninput();
ids.get('save').onclick();
assert.equal(messages.at(-1).action,'register');assert.equal(messages.at(-1).id,'my_script');assert.equal(messages.at(-1).title,'我的脚本');
receive({modules:[],success:false,message:'注册失败'});
assert.equal(ids.get('save').textContent,'注册并应用');
ids.get('save').onclick();assert.equal(messages.at(-1).id,'my_script');
receive({modules:[{id:'my_script',title:'我的脚本',enabled:true,running:true,options:{},defaults:{enabled:true,options:{}}}],savedID:'my_script',success:true});
assert.equal(ids.get('save').textContent,'保存并应用');assert.equal(ids.get('navigation').children.length,1);
console.log('PASS: UI edits, save payload, failed-save draft retention, defaults, rules, empty config, registration and retry');
