# Draws Resources/AppIcon.png (1024 px): a dusk sky with the Sun on the horizon.
# Usage: python3 Scripts/make_icon.py Resources/AppIcon.png   (needs Pillow)
import sys, math
from PIL import Image, ImageDraw, ImageFilter, ImageChops
S=1024; out=sys.argv[1]
def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(3))
stops=[(0.0,(12,22,58)),(0.38,(40,66,128)),(0.62,(120,110,160)),(0.74,(236,150,96)),(0.80,(252,196,120))]
sky=Image.new('RGB',(S,S))
px=sky.load()
for y in range(S):
    t=y/S
    for k in range(len(stops)-1):
        if stops[k][0]<=t<=stops[k+1][0]:
            c=lerp(stops[k][1],stops[k+1][1],(t-stops[k][0])/(stops[k+1][0]-stops[k][0])); break
    else: c=stops[-1][1]
    for x in range(S): px[x,y]=c
hz=800
# sun glow
glow=Image.new('L',(S,S),0); g=ImageDraw.Draw(glow)
g.ellipse((512-260,hz-260,512+260,hz+260),fill=200); glow=glow.filter(ImageFilter.GaussianBlur(110))
sky=Image.composite(Image.new('RGB',(S,S),(255,214,150)),sky,glow)
sun=Image.new('L',(S,S),0); d=ImageDraw.Draw(sun); d.ellipse((512-115,hz-115,512+115,hz+115),fill=255)
sun=sun.filter(ImageFilter.GaussianBlur(3))
sky=Image.composite(Image.new('RGB',(S,S),(255,244,214)),sky,sun)
# stars
st=Image.new('L',(S,S),0); d=ImageDraw.Draw(st)
for (x,y,r) in [(300,250,9),(690,190,7),(780,360,5),(420,140,4),(560,300,4),(250,420,3)]:
    d.ellipse((x-r,y-r,x+r,y+r),fill=255)
st=st.filter(ImageFilter.GaussianBlur(1.5))
sky=Image.composite(Image.new('RGB',(S,S),(240,244,255)),sky,st)
# hills
hill=Image.new('L',(S,S),0); d=ImageDraw.Draw(hill)
pts=[(0,S)]+[(x, hz+30-38*math.sin(x/170+0.6)-18*math.sin(x/70)) for x in range(0,S+1,8)]+[(S,S)]
d.polygon(pts,fill=255); hill=hill.filter(ImageFilter.GaussianBlur(1))
sky=Image.composite(Image.new('RGB',(S,S),(22,28,54)),sky,hill)
# squircle mask
M=4; big=Image.new('L',(S*M,S*M),0); d=ImageDraw.Draw(big)
m=100*M; d.rounded_rectangle((m,m,S*M-m,S*M-m),radius=185*M,fill=255)
mask=big.resize((S,S),Image.LANCZOS)
icon=Image.new('RGBA',(S,S),(0,0,0,0))
sh=mask.filter(ImageFilter.GaussianBlur(18)).point(lambda v:int(v*0.35))
shadow=Image.new('RGBA',(S,S),(0,0,0,0)); shadow.putalpha(ImageChops.offset(sh,0,12))
icon=Image.alpha_composite(icon,shadow)
body=sky.convert('RGBA'); body.putalpha(mask)
icon=Image.alpha_composite(icon,body)
icon.save(out)
