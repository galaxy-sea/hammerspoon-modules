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
  setAttribute(name,value) { this.attributes ||= {};this.attributes[name]=value; }
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
assert.deepEqual(messages.at(-1).options.rules,[''],'generic fallback must not invent browser rule templates');
receive({modules,savedID:'browser_dispatcher'});
// Empty Lua tables may be encoded as [], but root options must remain an editable group.
receive({modules:[{id:'empty',title:'空配置',enabled:false,running:false,options:[],defaults:{enabled:false,options:[]}}]});
assert(all(ids.get('content')).some(e=>e.textContent==='＋ 添加设置'));
// Generic settings must not show input-method-specific prompts.
assert(all(ids.get('content')).some(e=>e.placeholder==='设置名称'));
assert(!all(ids.get('content')).some(e=>e.placeholder?.includes('输入法')));
receive({modules:[{id:'input_assistant',title:'输入助手',enabled:true,running:true,options:{appInputSources:{'com.apple.keylayout.ABC':['com.apple.Terminal']}},defaults:{enabled:true,options:{}}}]});
assert(!all(ids.get('content')).some(e=>e.placeholder==='输入法 ID'));
assert(all(ids.get('content')).some(e=>e.placeholder==='设置名称'));
// Window resize uses its declared parameters, not the generic field editor.
const hotkeyParameters=[{key:'hotkey',label:'调整窗口快捷键',control:'hotkey',default:{mods:['ctrl','cmd','shift'],key:'5'}}];
const windowItem={id:'window_resize',title:'窗口调整',enabled:true,running:true,parameters:hotkeyParameters,options:{hotkey:{mods:['cmd'],key:'9'},extra:'preserved'},defaults:{enabled:true,options:{}}};
receive({modules:[windowItem]});
let controls=all(ids.get('content'));
assert(controls.some(e=>e.tagName==='h3'&&e.textContent==='调整窗口快捷键'));
assert(!controls.some(e=>e.textContent==='启用快捷键'));
assert(!controls.some(e=>e.tagName==='select'||e.textContent==='＋ 添加设置'||e.textContent==='删除'));
const ctrlLabel=controls.find(e=>e.tagName==='label'&&e.children.some(child=>child.textContent==='⌃ Control'));
const ctrl=ctrlLabel.children[0];assert.equal(ctrl.checked,false);ctrl.checked=true;ctrl.onchange();
const mainKey=controls.find(e=>e.className==='key-input');assert.equal(mainKey.value,'9');mainKey.value='8';mainKey.oninput();
assert(controls.some(e=>e.tagName==='kbd'&&e.textContent==='⌃⌘ 8'));
ids.get('save').onclick();
assert.deepEqual(messages.at(-1).options.hotkey,{mods:['cmd','ctrl'],key:'8'});
assert.equal(messages.at(-1).options.extra,'preserved');
receive({modules:[{...windowItem,options:[]}],savedID:'window_resize'});
assert.equal(all(ids.get('content')).find(e=>e.className==='key-input').value,'5','missing config must display declared defaults');
ids.get('save').onclick();assert.deepEqual(messages.at(-1).options,{},'opening and saving must not overwrite absent options with displayed defaults');
receive({modules:[windowItem],savedID:'window_resize'});
// Camera parameters use grouped scalar fields and compact lists, with no generic controls.
const cameraParameters=[
 {label:'邮件通知',fields:[{key:'account',label:'邮件账户',default:'default'},{key:'deviceName',label:'设备名称（邮件标题前缀）',default:''},{key:'to',label:'收件地址',default:[]}]},
 {label:'拍照安排',fields:[{key:'lockedInterval',label:'锁屏拍照间隔（秒）',default:5}]},
 {label:'跳过的 Wi-Fi',fields:[{key:'ignoredSSIDs',label:'不拍照和发信的 Wi-Fi',default:{}}]},
 {label:'高级设置',collapsed:true,fields:[{key:'warmup',label:'摄像头预热（秒）',default:0.5}]},
];
const cameraItem={id:'lockscreen_camera',title:'解锁拍照',enabled:true,running:true,parameters:cameraParameters,options:{account:'mail',to:'first@example.com',ignoredSSIDs:['Home'],deviceName:'preserve this'},defaults:{enabled:true,options:{}}};
receive({modules:[cameraItem]});
controls=all(ids.get('content'));
assert(controls.some(e=>e.tagName==='h3'&&e.textContent==='邮件通知'));
assert(!controls.some(e=>e.tagName==='select'||e.textContent==='＋ 添加设置'||e.textContent==='删除'));
const advanced=controls.find(e=>e.tagName==='details'&&e.className.includes('collapsible-parameters'));assert(advanced&&!advanced.open);
assert.equal(ids.get('parameter-lockedInterval').value,5);
const deviceNameInput=ids.get('parameter-deviceName');assert.equal(deviceNameInput.value,'preserve this');deviceNameInput.value='My Mac';deviceNameInput.oninput();
assert.equal(ids.get('parameter-warmup').value,0.5);
const cameraField=label=>all(ids.get('content')).find(e=>e.className==='parameter-field'&&e.children[0].textContent===label);
const recipients=cameraField('收件地址');assert.equal(all(recipients).find(e=>e.tagName==='input').value,'first@example.com');
all(recipients).find(e=>e.className==='list-add').onclick();
let recipientInputs=all(recipients).filter(e=>e.tagName==='input');recipientInputs[1].value='second@example.com';recipientInputs[1].oninput();
all(recipients).find(e=>e.className==='list-remove').onclick();
const wifi=cameraField('不拍照和发信的 Wi-Fi');all(wifi).find(e=>e.className==='list-add').onclick();
const wifiInputs=all(wifi).filter(e=>e.tagName==='input');wifiInputs[1].value='Office';wifiInputs[1].oninput();
const warmup=ids.get('parameter-warmup');warmup.value='0.75';warmup.oninput();
ids.get('save').onclick();
assert.deepEqual(messages.at(-1).options.to,['second@example.com']);
assert.deepEqual(messages.at(-1).options.ignoredSSIDs,['Home','Office']);
assert.equal(messages.at(-1).options.warmup,0.75);assert.equal(messages.at(-1).options.deviceName,'My Mac');
assert(!Object.hasOwn(messages.at(-1).options,'lockedInterval'),'displayed defaults must not be written just by opening the form');
receive({modules:[cameraItem],savedID:'lockscreen_camera'});
ids.get('reset').onclick();
assert(!all(cameraField('收件地址')).some(e=>e.tagName==='input'),'reset must show an empty recipient list');
const emptyWifi=cameraField('不拍照和发信的 Wi-Fi');all(emptyWifi).find(e=>e.className==='list-add').onclick();
assert.equal(all(emptyWifi).filter(e=>e.tagName==='input').length,1,'empty Lua tables must still offer list controls');
// Reminder form keeps its test hotkey optional and its snooze values numeric.
const reminderParameters=[
 {label:'提醒时间',fields:[{key:'intervalMinutes',label:'提醒间隔（分钟）',default:20},{key:'snoozeMinutes',label:'延后时间（分钟）',default:[1,5,10]}]},
 {label:'休息确认',fields:[{key:'hoverSeconds',label:'每次悬停时间（秒）',default:10},{key:'hoverCount',label:'悬停确认次数',default:3}]},
 {key:'hotkey',label:'测试快捷键',control:'hotkey',enableLabel:'启用测试',default:{mods:['ctrl','alt','cmd'],key:'B',bind:false}},
];
const reminderItem={id:'blink_reminder',title:'休息提醒',enabled:true,running:true,parameters:reminderParameters,options:{intervalMinutes:30,snoozeMinutes:[5,10]},defaults:{enabled:true,options:{}}};
receive({modules:[reminderItem],savedID:'blink_reminder'});
controls=all(ids.get('content'));
assert(!controls.some(e=>e.tagName==='select'||e.textContent==='＋ 添加设置'));
let testToggle=controls.find(e=>e.attributes?.['aria-label']==='启用测试快捷键');assert.equal(testToggle.checked,false);
const snoozes=cameraField('延后时间（分钟）');all(snoozes).find(e=>e.className==='list-add').onclick();
const snoozeInputs=all(snoozes).filter(e=>e.tagName==='input');assert.equal(snoozeInputs[2].type,'number');snoozeInputs[2].value='15';snoozeInputs[2].oninput();
const reminderKey=controls.find(e=>e.className==='key-input');reminderKey.value='R';reminderKey.oninput();
ids.get('save').onclick();assert.deepEqual(messages.at(-1).options.snoozeMinutes,[5,10,15]);assert.equal(messages.at(-1).options.hotkey.bind,false);
receive({modules:[reminderItem],savedID:'blink_reminder'});
testToggle=all(ids.get('content')).find(e=>e.attributes?.['aria-label']==='启用测试快捷键');testToggle.checked=true;testToggle.onchange();
ids.get('save').onclick();assert.equal(messages.at(-1).options.hotkey.bind,true);assert.equal(messages.at(-1).options.hotkey.key,'B');
receive({modules:[{...reminderItem,options:{hotkey:{mods:['cmd'],key:'B'}}}],savedID:'blink_reminder'});
assert.equal(all(ids.get('content')).find(e=>e.attributes?.['aria-label']==='启用测试快捷键').checked,true,'existing hotkey with omitted bind remains enabled');
// Parameterless scripts expose only their global enable switch, even with saved legacy hotkeys.
for(const parameters of [[],{}]){
 receive({modules:[{id:'close_last_window_hide',title:'自动隐藏应用',enabled:true,running:true,parameters,options:{hotkey:{mods:['cmd'],key:'W'}},defaults:{enabled:true,options:{}}}],savedID:'close_last_window_hide'});
 controls=all(ids.get('content'));
 assert(controls.some(e=>e.textContent==='此脚本无需配置，启用后自动运行。'));
 assert.equal(controls.filter(e=>e.tagName==='input').length,1);
 assert(!controls.some(e=>e.className==='key-input'||e.textContent==='＋ 添加设置'));
}
// Application selection uses the native file picker; opening the form does not scan apps.
const mtpItem={id:'usb_MTP_finder',title:'MTP 软件启停',enabled:true,running:true,parameters:[{label:'文件传输软件',fields:[{key:'appBundleID',label:'选择软件',default:'',options:'application'},{key:'disconnectDelay',label:'断开确认等待（秒）',default:1}]}],options:{appBundleID:'com.sudomaker.MacMTP'},defaults:{enabled:true,options:{}}};
const beforePicker=messages.length;receive({modules:[mtpItem]});assert.equal(messages.length,beforePicker);
let browse=all(ids.get('content')).find(e=>e.textContent==='在访达中选择…');browse.onclick();
assert.deepEqual(messages.at(-1),{action:'chooseApplication',id:'usb_MTP_finder',key:'appBundleID'});
context.window.receiveApplication({id:'usb_MTP_finder',key:'appBundleID'});
assert.equal(ids.get('parameter-appBundleID').value,'com.sudomaker.MacMTP','cancel must preserve current selection');
browse=all(ids.get('content')).find(e=>e.textContent==='在访达中选择…');assert.equal(browse.disabled,false);browse.onclick();
context.window.receiveApplication({id:'usb_MTP_finder',key:'appBundleID',application:{id:'com.openmtp',name:'OpenMTP'}});
assert.equal(ids.get('parameter-appBundleID').value,'com.openmtp');
assert(all(ids.get('content')).some(e=>e.textContent==='OpenMTP'));
ids.get('save').onclick();assert.equal(messages.at(-1).options.appBundleID,'com.openmtp');
receive({modules:[mtpItem],savedID:'usb_MTP_finder'});
const manualID=ids.get('parameter-appBundleID');manualID.value='com.custom.mtp';manualID.oninput();
context.window.receiveApplication({id:'usb_MTP_finder',key:'appBundleID',error:'不是有效应用'});
assert.equal(ids.get('parameter-appBundleID').value,'com.custom.mtp');assert.equal(ids.get('notice').textContent,'不是有效应用');
ids.get('save').onclick();assert.equal(messages.at(-1).options.appBundleID,'com.custom.mtp');
receive({modules:[mtpItem],savedID:'usb_MTP_finder'});
// Scheduled webpages use plan cards; preserve old string/array forms until edited.
const scheduleParameters=[{key:'schedules',label:'网页计划',itemLabel:'计划',layout:'columns',default:[],fields:[{key:'enabled',label:'启用计划',default:true,header:true},{key:'url',label:'打开的网址',default:['https://example.com']},{key:'cron',label:'执行时间（Linux Cron：分 时 日 月 星期）',default:['0 9 * * 1-5']}]}];
const scheduleItem={id:'scheduled_webpages',title:'定时打开网页',enabled:true,running:true,parameters:scheduleParameters,options:{schedules:[{url:'https://work.example.test',cron:['0 14 * * *','0 17 * * *']}]},defaults:{enabled:true,options:{}}};
receive({modules:[scheduleItem]});
controls=all(ids.get('content'));assert(!controls.some(e=>e.tagName==='select'||e.textContent==='＋ 添加设置'));
assert(!all(ids.get('content')).some(e=>e.textContent==='计划名称'));
let planToggle=controls.find(e=>e.attributes?.['aria-label']==='启用计划 1');assert.equal(planToggle.checked,true);planToggle.checked=false;planToggle.onchange();
ids.get('save').onclick();
assert(!Object.hasOwn(messages.at(-1).options.schedules[0],'name'));assert.equal(messages.at(-1).options.schedules[0].enabled,false);
assert.equal(messages.at(-1).options.schedules[0].url,'https://work.example.test');assert.deepEqual(messages.at(-1).options.schedules[0].cron,['0 14 * * *','0 17 * * *']);
receive({modules:[scheduleItem],savedID:'scheduled_webpages'});
all(ids.get('content')).find(e=>e.textContent==='＋ 添加计划').onclick();
assert.equal(all(ids.get('content')).filter(e=>e.className==='parameter-columns').length,2);
ids.get('save').onclick();assert.equal(messages.at(-1).options.schedules.length,2);assert.deepEqual(messages.at(-1).options.schedules[1].url,['https://example.com']);
receive({modules:[scheduleItem],savedID:'scheduled_webpages'});
all(ids.get('content')).find(e=>e.attributes?.['aria-label']==='删除计划 1').onclick();
assert(all(ids.get('content')).some(e=>e.textContent==='暂无网页计划，点击下方添加。'));
ids.get('save').onclick();assert.deepEqual(messages.at(-1).options.schedules,[]);
receive({modules:[{...scheduleItem,options:{schedules:[]}}],savedID:'scheduled_webpages'});
all(ids.get('content')).find(e=>e.textContent==='＋ 添加计划').onclick();
const newUrls=cameraField('打开的网址');const urlInput=all(newUrls).find(e=>e.tagName==='input');urlInput.value='https://new.example.test';urlInput.oninput();
ids.get('save').onclick();assert.deepEqual(messages.at(-1).options.schedules[0].url,['https://new.example.test']);
receive({modules:[scheduleItem],savedID:'scheduled_webpages'});
// Browser routing: folded globals, exact mode serialization, ordered rules, optional match fields.
const browserOptions=[{value:'chrome',label:'Chrome'},{value:'edge',label:'Edge'},{value:'safari',label:'Safari'},{value:'firefox',label:'Firefox'}];
const routingParameters=[
 {label:'浏览器与用户配置',collapsed:true,layout:'columns',fields:[{key:'browsers',label:'浏览器列表（第一项为默认）',default:['chrome','edge','safari','firefox'],options:browserOptions},{key:'profiles',label:'用户配置列表（第一项为默认）',default:['Default','Profile 1']}]},
 {key:'rules',label:'分流规则',itemLabel:'规则',layout:'columns',default:[],template:{urls:['example.com']},fields:[
  {label:'匹配条件',fields:[{key:'urls',label:'匹配网址',default:[],omitEmpty:true},{key:'apps',label:'来源软件名称',default:[],omitEmpty:true},
   {label:'高级匹配',collapsed:true,fields:[{key:'patterns',label:'Lua 匹配模式',default:[],omitEmpty:true}]}]},
  {label:'打开方式',fields:[{key:'browser',label:'浏览器',default:'',options:browserOptions,selection:{source:'browsers',choose:'choose'}},
   {key:'profile',label:'用户配置',default:'',selection:{source:'profiles',choose:'choose'},disabledWhen:{key:'browser',source:'browsers',values:['safari','com.apple.Safari'],message:'Safari 不使用用户配置。'}}]},
 ]},
 {label:'高级设置',collapsed:true,fields:[{key:'logLevel',label:'日志级别',default:'info',options:[{value:'info',label:'常规'},{value:'debug',label:'调试'}]}]},
];
const routingItem={id:'browser_dispatcher',title:'浏览器分流',enabled:true,running:true,parameters:routingParameters,options:{browsers:['chrome','edge'],profiles:['Default','Profile 133'],rules:[{urls:'www.jlc.com/newOrder',profile:'choose'}]},defaults:{enabled:true,options:{}}};
const aria=label=>all(ids.get('content')).find(e=>e.attributes?.['aria-label']===label);
receive({modules:[routingItem],savedID:'browser_dispatcher'});
controls=all(ids.get('content'));
const globals=controls.find(e=>e.tagName==='details'&&e.children[0]?.textContent==='浏览器与用户配置');assert(globals&&!globals.open);
assert.equal(controls.filter(e=>e.className==='parameter-columns').length,2);
assert(!controls.some(e=>e.textContent==='↑'||e.textContent==='↓'),'HTML must not introduce reorder controls');
assert(!controls.some(e=>e.textContent==='＋ 添加设置'||e.textContent==='计划名称'||e.textContent==='启用'));
ids.get('save').onclick();assert.deepEqual(messages.at(-1).options,routingItem.options,'opening/saving must preserve strings and omitted match fields');
receive({modules:[routingItem],savedID:'browser_dispatcher'});
let mode=aria('浏览器选择方式');assert.equal(mode.value,'default');mode.value='choose';mode.onchange();
mode=aria('用户配置选择方式');assert.equal(mode.value,'choose');mode.value='custom';mode.onchange();
ids.get('save').onclick();assert.equal(messages.at(-1).options.rules[0].browser,'choose');assert.deepEqual(messages.at(-1).options.rules[0].profile,['Default','Profile 133']);
receive({modules:[routingItem],savedID:'browser_dispatcher'});
mode=aria('浏览器选择方式');mode.value='fixed';mode.onchange();let fixed=aria('固定浏览器');fixed.value='safari';fixed.onchange();
assert(all(ids.get('content')).some(e=>e.textContent==='Safari 不使用用户配置。'));assert(!aria('用户配置选择方式'));
fixed=aria('固定浏览器');fixed.value='chrome';fixed.onchange();assert(aria('用户配置选择方式'));
mode=aria('浏览器选择方式');mode.value='custom';mode.onchange();ids.get('save').onclick();assert.deepEqual(messages.at(-1).options.rules[0].browser,['chrome','edge']);
receive({modules:[routingItem],savedID:'browser_dispatcher'});
assert(all(ids.get('content')).some(e=>e.textContent==='默认：Chrome'));
mode=aria('用户配置选择方式');mode.value='default';mode.onchange();
const sourceApps=cameraField('来源软件名称');all(sourceApps).find(e=>e.className==='list-add').onclick();const sourceInput=all(sourceApps).find(e=>e.tagName==='input');sourceInput.value='微信';sourceInput.oninput();
const urlsField=cameraField('匹配网址');all(urlsField).find(e=>e.className==='list-remove').onclick();
ids.get('save').onclick();let savedRule=messages.at(-1).options.rules[0];assert.deepEqual(savedRule,{apps:['微信']});assert.deepEqual(messages.at(-1).options.browsers,['chrome','edge']);
receive({modules:[routingItem],savedID:'browser_dispatcher'});
all(ids.get('content')).find(e=>e.textContent==='＋ 添加规则').onclick();
ids.get('save').onclick();assert.equal(messages.at(-1).options.rules[0].urls,'www.jlc.com/newOrder');assert.deepEqual(messages.at(-1).options.rules[1],{urls:['example.com']});
receive({modules:[routingItem],savedID:'browser_dispatcher'});aria('删除规则 1').onclick();ids.get('save').onclick();assert.deepEqual(messages.at(-1).options.rules,[]);
receive({modules:[routingItem],savedID:'browser_dispatcher'});
// Advanced-only rules remain advanced-only, and a fixed profile is stored as a string.
const advancedRule={patterns:'^https?://example%.com/items/%d+$',browser:'firefox',profile:'default-release'};
receive({modules:[{...routingItem,options:{...routingItem.options,rules:[advancedRule]}}],savedID:'browser_dispatcher'});
assert(all(ids.get('content')).some(e=>e.tagName==='details'&&e.children[0]?.textContent==='高级匹配'&&!e.open));
ids.get('save').onclick();assert.deepEqual(messages.at(-1).options.rules[0],advancedRule);
receive({modules:[routingItem],savedID:'browser_dispatcher'});
mode=aria('用户配置选择方式');mode.value='fixed';mode.onchange();const fixedProfile=aria('固定用户配置');fixedProfile.value='Profile 133';fixedProfile.oninput();
ids.get('save').onclick();assert.equal(messages.at(-1).options.rules[0].profile,'Profile 133');
receive({modules:[routingItem],savedID:'browser_dispatcher'});
// Unrelated metadata names prove that order, layout, collapse, records and selection are not hardcoded.
const genericParameters=[
 {label:'First arbitrary section',collapsed:true,layout:'columns',fields:[{key:'zeta',label:'Z first',default:1},{key:'alpha',label:'A second',default:2}]},
 {label:'高级设置',fields:[{key:'plain',label:'Not folded by its label',default:'value'}]},
 {key:'destinations',label:'Custom source',default:['one','two']},
 {key:'jobs',label:'Custom jobs',itemLabel:'任务',layout:'columns',default:[],template:{tag:'new'},fields:[
  {key:'active',label:'任务开关',default:true,header:true},
  {label:'Left',fields:[{key:'conditions',label:'Custom conditions',default:[],omitEmpty:true}]},
  {label:'Right',fields:[{key:'destination',label:'Custom destination',default:'',selection:{source:'destinations',choose:'ask'}}]},
 ]},
];
const genericItem={id:'generic_metadata',title:'Generic',enabled:false,running:false,parameters:genericParameters,options:{jobs:[{conditions:['x'],destination:'ask'}]},defaults:{enabled:false,options:{}}};
receive({modules:[genericItem]});controls=all(ids.get('content'));
let form=ids.get('settings-form');assert.equal(form.children[0].tagName,'details');assert.equal(form.children[0].open,false);
assert.equal(form.children[1].tagName,'section','a label must not imply folding');
const orderedLabels=all(form.children[0]).filter(e=>e.className==='field-label').map(e=>e.textContent);assert.deepEqual(orderedLabels,['Z first','A second']);
assert(!controls.some(e=>e.textContent==='↑'||e.textContent==='↓'));
let destinationMode=aria('Custom destination选择方式');assert.equal(destinationMode.value,'choose');destinationMode.value='default';destinationMode.onchange();
ids.get('save').onclick();assert(!Object.hasOwn(messages.at(-1).options.jobs[0],'destination'));assert(!Object.hasOwn(messages.at(-1).options.jobs[0],'enabled'));
receive({modules:[genericItem],savedID:'generic_metadata'});
all(ids.get('content')).find(e=>e.textContent==='＋ 添加任务').onclick();ids.get('save').onclick();assert.deepEqual(messages.at(-1).options.jobs[1],{tag:'new'});
receive({modules:[genericItem],savedID:'generic_metadata'});
// Input assistant uses dynamic source choices and metadata-defined maps, preserving grouped Source IDs.
const sourceOptions=[{value:'com.apple.keylayout.ABC',label:'ABC'},{value:'org.fcitx.inputmethod.Fcitx5.zhHans',label:'Fcitx5'}];
const regionOptions=[{value:'chromeAddress',label:'Chrome 地址栏'},{value:'vscodeConsolePanel',label:'VS Code 控制台面板'},{value:'vscodeChat',label:'VS Code ChatGPT / Codex 聊天输入框'}];
const inputParameters=[
 {label:'基础设置',fields:[{key:'defaultSource',label:'默认输入法',default:sourceOptions[1].value,options:'inputSources'}]},
 {label:'英文标点',fields:[{key:'englishPunctuation',label:'使用英文标点的应用',default:[],item:{options:'application'}}]},
 {key:'appInputSources',label:'应用输入法分组',control:'map',default:{},itemLabel:'输入法分组',keyField:{label:'输入法',default:'',options:'inputSources'},valueField:{label:'应用 Bundle ID',default:[],item:{options:'application'}}},
 {key:'focusInputSources',label:'输入区域分组',control:'map',default:{},itemLabel:'输入法分组',keyField:{label:'输入法',default:'',options:'inputSources'},valueField:{label:'输入区域',default:[],options:regionOptions}},
];
const inputItem={id:'input_assistant',title:'输入助手',enabled:true,running:true,parameters:inputParameters,options:{defaultSource:sourceOptions[1].value,englishPunctuation:['com.microsoft.VSCode'],appInputSources:{'com.apple.keylayout.ABC':['com.apple.Terminal']},focusInputSources:{'com.apple.keylayout.ABC':['chromeAddress','vscodeConsolePanel'],'org.fcitx.inputmethod.Fcitx5.zhHans':['vscodeChat']}},defaults:{enabled:true,options:{}}};
receive({modules:[inputItem],savedID:'input_assistant'});assert.deepEqual(messages.at(-1),{action:'options',source:'inputSources'});
context.window.receiveOptions({source:'inputSources',options:sourceOptions});
assert.equal(aria('默认输入法').value,sourceOptions[1].value);
aria('默认输入法').value=sourceOptions[0].value;aria('默认输入法').onchange();
const punctuationField=cameraField('使用英文标点的应用');all(punctuationField).find(e=>e.textContent==='在访达中添加…').onclick();
const appRequest=messages.at(-1);assert.equal(appRequest.action,'chooseApplication');assert(appRequest.request);
context.window.receiveApplication({id:'input_assistant',request:appRequest.request,application:{id:'com.demo.Editor',name:'Demo Editor'}});
const appMap=all(ids.get('content')).find(e=>e.className==='map-list'&&e.children[0].textContent==='应用输入法分组');
const appSource=all(appMap).find(e=>e.tagName==='select'&&e.attributes?.['aria-label']==='输入法');appSource.value=sourceOptions[1].value;appSource.onchange();
const appTargets=all(appMap).find(e=>e.className==='parameter-field'&&e.children[0].textContent==='应用 Bundle ID');
all(appTargets).find(e=>e.textContent==='在访达中添加…').onclick();const targetRequest=messages.at(-1);
context.window.receiveApplication({id:'input_assistant',request:targetRequest.request,application:{id:'com.example.Tool',name:'Tool'}});
const focusMap=all(ids.get('content')).find(e=>e.className==='map-list'&&e.children[0].textContent==='输入区域分组');
let focusSourceSelectors=all(focusMap).filter(e=>e.tagName==='select'&&e.attributes?.['aria-label']==='输入法');
focusSourceSelectors[1].value=sourceOptions[0].value;focusSourceSelectors[1].onchange();
assert.equal(ids.get('notice').textContent,'该分组名称已存在，请直接编辑已有分组。');
focusSourceSelectors=all(focusMap).filter(e=>e.tagName==='select'&&e.attributes?.['aria-label']==='输入法');assert.equal(focusSourceSelectors[1].value,sourceOptions[1].value);
ids.get('save').onclick();const inputSaved=messages.at(-1).options;
assert.equal(inputSaved.defaultSource,sourceOptions[0].value);
assert.deepEqual(inputSaved.englishPunctuation,['com.microsoft.VSCode','com.demo.Editor']);
assert.deepEqual(inputSaved.appInputSources,{'org.fcitx.inputmethod.Fcitx5.zhHans':['com.apple.Terminal','com.example.Tool']});
assert.deepEqual(inputSaved.focusInputSources,inputItem.options.focusInputSources);
const sourceRequestCount=messages.filter(m=>m.action==='options').length;
receive({modules:[inputItem],savedID:'input_assistant'});assert.equal(messages.filter(m=>m.action==='options').length,sourceRequestCount);
const freshAppMap=all(ids.get('content')).find(e=>e.className==='map-list'&&e.children[0].textContent==='应用输入法分组');
all(freshAppMap).find(e=>e.attributes?.['aria-label']==='删除应用输入法分组 1').onclick();
ids.get('save').onclick();assert.deepEqual(messages.at(-1).options.appInputSources,{});
receive({modules:[inputItem],savedID:'input_assistant'});
assert(!html.includes('id="register"'), 'automatic discovery needs no registration button');
console.log('PASS: UI edits, save payload, failed-save draft retention, defaults, metadata forms and source groups');
