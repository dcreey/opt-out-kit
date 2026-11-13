import asyncio, json, sys, re
from playwright.async_api import async_playwright
H=open('tools/chrome_load_check/h.js').read().rstrip(); H=H[:H.rindex('JSON.stringify(out)')]+'return JSON.stringify(out)'
sites=json.load(open('tools/chrome_load_check/sites.json'))
only=set(sys.argv[1].split(',')) if len(sys.argv)>1 and sys.argv[1] else None
if only: sites=[s for s in sites if s['d'] in only]
DENY="""()=>{const re=/^(reject all|reject|decline|deny|no thanks|only necessary|necessary only|refuse|disagree|i do not accept)/i;
 const b=[...document.querySelectorAll('button,a,[role=button]')].find(e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&re.test((e.innerText||'').trim())});if(b){b.click();return 1}return 0}"""
RIGHTS="""()=>{let ch=0;[...document.querySelectorAll('select')].forEach(s=>{if(ch||s.closest('form'))return;const r=s.getBoundingClientRect();if(r.width<=0)return;const bad=/opt.?in|\\bknow\\b|access|correct|portab|copy of|subscribe/i;const o=[...s.options];const p=o.find(x=>/opt.?out|do not sell|don.?t sell/i.test(x.text)&&!bad.test(x.text))||o.find(x=>/\\b(delet|eras|remov)\\w*/i.test(x.text)&&!bad.test(x.text));if(p&&s.value!==p.value){s.value=p.value;s.dispatchEvent(new Event('input',{bubbles:true}));s.dispatchEvent(new Event('change',{bubbles:true}));ch=1}});return ch}"""
NEXT="""()=>{if(!/opt.?out|do.?not.?sell|remove|ccpa|privacy.?(request|rights|choices)/i.test(location.pathname+' '+document.title))return 0;const cs=[...document.querySelectorAll('button,a,[role=button]')].filter(e=>{const t=(e.innerText||'').replace(/\\s+/g,' ').trim();const r=e.getBoundingClientRect();return /^(continue|next|get started|begin|proceed|start)$/i.test(t)&&r.width>0&&r.height>0&&!e.disabled&&!e.closest('form,[id*=cookie i],[class*=cookie i],[id*=consent i],[class*=consent i],[role=dialog],[aria-modal=true]')});if(cs.length!==1)return 0;cs[0].click();return 1}"""
START="""()=>{const re=/^(start .{3,50} request|exert (my )?right to opt.?out|delete (my|your) (user )?(personal )?(data|information)|opt.?out of (the )?(sale|sharing)( (and|or) sharing)?|opt.?out form|do not sell( or share)?( my (personal )?(information|data))?|opt.?out|remove me)$/i;
 const e=[...document.querySelectorAll('button,[role=button],a')].find(e=>{const t=(e.innerText||'').replace(/\\s+/g,' ').trim();const r=e.getBoundingClientRect();return re.test(t)&&r.width>0&&r.height>0&&(e.tagName!=='A'||!e.getAttribute('href')||/^(#|javascript)/.test(e.getAttribute('href')))});if(e){e.click();return 1}return 0}"""
async def one(br, s, sem, out):
    async with sem:
        res={'d':s['d'],'p':s['p'],'a':s['a']}
        ctx=await br.new_context(viewport={'width':390,'height':844},is_mobile=True,has_touch=True,user_agent='Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1')
        pg=await ctx.new_page()
        try:
            r=await pg.goto(s['p'],timeout=30000,wait_until='domcontentloaded')
            res['http']=r.status if r else None
            await pg.wait_for_timeout(3500)
            try: await pg.evaluate(DENY); await pg.wait_for_timeout(800)
            except Exception: pass
            steps=[]
            async def read():
                try: return json.loads(await pg.evaluate("()=>{"+H+"}"))
                except Exception as e: return {'err':str(e)[:80]}
            for nm,js in (('start',START),('rights',RIGHTS)):
                try:
                    if await pg.evaluate(js): steps.append(nm); await pg.wait_for_timeout(2500)
                except Exception: pass
            o=await read()
            for _ in range(2):
                if o.get('pick') or o.get('err'): break
                acted=False
                for nm,js in (('next',NEXT),('start',START),('rights',RIGHTS)):
                    try:
                        if await pg.evaluate(js): steps.append(nm); acted=True; await pg.wait_for_timeout(2500); break
                    except Exception: pass
                if not acted: break
                o=await read()
            res.update(o); res['steps']=steps; res['final']=pg.url[:120]
            if o.get('pick'):
                try:
                    loc=pg.locator('[data-ookpick]').first
                    await loc.scroll_into_view_if_needed(timeout=3000)
                    await loc.screenshot(path='/tmp/claude-501/h/shots/'+s['d']+'.png',timeout=8000)
                    res['shot']=1
                except Exception as e:
                    res['shot']=0
                    try: await pg.screenshot(path='/tmp/claude-501/h/shots/'+s['d']+'.png'); res['shot']=2
                    except Exception: pass
        except Exception as e:
            res['err']=str(e)[:100]
        finally:
            await ctx.close()
        out.write(json.dumps(res)+'\n'); out.flush()
async def main():
    sem=asyncio.Semaphore(8)
    async with async_playwright() as p:
        br=await p.chromium.launch(channel='chrome',headless=True)
        with open('/tmp/claude-501/h/results6.jsonl','w') as out:
            await asyncio.gather(*[one(br,s,sem,out) for s in sites])
        await br.close()
asyncio.run(main())
