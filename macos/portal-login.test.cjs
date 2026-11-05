// Isolated synthetic DOM tests. No browser, real accounts, network, or secret storage.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, 'portal-login.js'), 'utf8');
const login = 'https://portal.example.com:9978/admin.php?controller=admin_index&action=login';
const credentials = {username:'synthetic-user',password:'synthetic-password'};
let checks = 0;
function fixture() {
  let clicks = 0;
  const form = {action:login,method:'post'};
  class Input {
    constructor(type,placeholder) {this.type=type;this.placeholder=placeholder;this.form=form;this.isConnected=true;this._value='';}
    get value(){return this._value;}
    set value(v){this._value=v;}
    getAttribute(name){return this[name] || null;}
    getClientRects(){return [1];}
    dispatchEvent(){if(this.onEvent)this.onEvent();}
    closest(){return this.form;}
  }
  const user=new Input('text','用户名：'),secret=new Input('password','口令：'),button=new Input('submit','');
  button.innerText='登 录';button.click=()=>{clicks++;};
  const inputs=[user,secret];
  const buttons=[button],captchas=[];
  const location={href:login};
  const document={readyState:'complete',body:{innerText:''},querySelectorAll(selector){
    if(selector==='input')return inputs;
    if(selector.startsWith('button,'))return buttons;
    return captchas;
  }};
  const window={};window.top=window;
  const context=vm.createContext({URL,window,document,location,HTMLInputElement:Input,Event:class{},getComputedStyle:()=>({visibility:'visible'})});
  vm.runInContext(source,context);
  return {user,secret,button,form,inputs,buttons,captchas,document,location,window,
    run:(c=null)=>context.portalLogin(c),clicks:()=>clicks};
}
function check(name, setup, expected, c=credentials) {
  const f=fixture();setup(f);assert.equal(f.run(c),expected,name);
  if(expected!=='SUBMITTED')assert.equal(f.clicks(),0,name+' did not submit');
  checks++;
}
check('probe is read only',()=>{},'READY',null);
const positive=fixture();assert.equal(positive.run(credentials),'SUBMITTED');assert.equal(positive.clicks(),1);
assert.equal(positive.user.value,credentials.username);assert.equal(positive.secret.value,credentials.password);checks++;
check('wrong host',f=>f.location.href=login.replace('portal.example.com','evil.invalid'),'BLOCKED');
check('HTTP forbidden',f=>f.location.href=login.replace('https:','http:'),'BLOCKED');
check('wrong port',f=>f.location.href=login.replace('9978','9980'),'BLOCKED');
check('duplicate controller',f=>f.location.href+='&controller=admin_index','BLOCKED');
check('duplicate action',f=>f.location.href+='&action=login','BLOCKED');
check('subframe forbidden',f=>f.window.top={},'BLOCKED');
check('loading',f=>f.document.readyState='loading','WAIT');
check('duplicate username',f=>f.inputs.push(f.user),'BLOCKED');
check('duplicate button',f=>f.buttons.push(f.button),'BLOCKED');
check('invisible/disconnected',f=>f.secret.isConnected=false,'BLOCKED');
check('wrong secret type',f=>f.secret.type='text','BLOCKED');
check('dynamic field masquerading as password',f=>f.secret.name='otp','BLOCKED');
check('cross-origin form',f=>f.form.action='https://evil.invalid/','BLOCKED');
check('cross-origin button',f=>f.button.formaction='https://evil.invalid/','BLOCKED');
check('GET refused',f=>f.form.method='get','BLOCKED');
check('required OTP',f=>{f.inputs.push(Object.assign(Object.create(Object.getPrototypeOf(f.user)),{isConnected:true,required:true,placeholder:'动态密码：',_value:''}));},'MANUAL');
check('captcha',f=>f.captchas.push(f.user),'MANUAL');
check('empty credentials',()=>{},'BLOCKED',{username:'',password:'x'});
check('origin changes during username fill',f=>f.user.onEvent=()=>{f.location.href='https://evil.invalid/';},'BLOCKED');
const changed=fixture();changed.secret.onEvent=()=>changed.form.action='https://evil.invalid/';
assert.equal(changed.run(credentials),'BLOCKED');assert.equal(changed.secret.value,'');assert.equal(changed.clicks(),0);checks++;
check('signed in page requires evidence',f=>f.location.href=login.replace('&action=login',''),'BLOCKED',null);
check('signed in',f=>{f.location.href=login.replace('&action=login','');f.document.body.innerText='监控设备(2) 退出';},'SIGNED_IN',null);
console.log(`PASS ${checks} isolated portal form checks; no network or real credentials.`);
