import sys
p = '/build/chromium/src/chrome/browser/chrome_content_browser_client.cc'
t = open(p).read()

old = '#if BUILDFLAG(ENABLE_IPFS)\n  if (!web_contents) {'
print(f"Pattern found: {old in t}")

if old in t:
    new = ('#if BUILDFLAG(ENABLE_IPFS)\n'
           '#if !(BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(ENABLE_EXTENSIONS_CORE) || \\\n'
           '      !BUILDFLAG(IS_ANDROID))\n'
           '  content::RenderFrameHost* frame_host =\n'
           '      RenderFrameHost::FromID(render_process_id, render_frame_id);\n'
           '  WebContents* web_contents = WebContents::FromRenderFrameHost(frame_host);\n'
           '#endif\n'
           '  if (!web_contents) {')
    t = t.replace(old, new, 1)
    open(p, 'w').write(t)
    print('Patched successfully')
else:
    print('Pattern not found')
