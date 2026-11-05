const state=document.getElementById('state');
async function message(data){const r=await chrome.runtime.sendMessage(data);if(r?.error)throw Error(r.error);return r;}
async function refresh(){
 const r=await message({type:'status'}),lines=[];
 lines.push(r.receiver?.configured?'本机已连接 · 推送已配置':(r.receiver?.message||'请启动“网页告警设置”并连接配对码'));
 lines.push(r.monitor?'当前有一个标签页正在监控':'尚未开启网页监控');
 if(r.heartbeat&&r.monitor&&Date.now()-r.heartbeat.time>45000)lines.push('页面心跳中断，请检查休眠、冻结或页面是否仍打开');
 if(r.heartbeat?.canvas)lines.push('检测到画布：若邮件是远程画面，请用OCR入口');
 if(r.heartbeat&&r.heartbeat.readable<20)lines.push('可读文本很少，可能无法读取邮件');
 if(r.lastResult)lines.push(r.lastResult);if(r.queue?.length)lines.push('待确认告警：'+r.queue.length);
 state.textContent=lines.join('\n');
}
for(const id of ['pair','start','stop','refresh'])document.getElementById(id).addEventListener('click',async()=>{
 const b=document.getElementById(id);b.disabled=true;
 try{if(id!=='refresh')await message({type:id,...(id==='pair'?{token:document.getElementById('token').value.trim()}:{})});document.getElementById('token').value='';await refresh();}
 catch(e){state.textContent=e.message;}finally{b.disabled=false;}
});refresh().catch(e=>state.textContent=e.message);
