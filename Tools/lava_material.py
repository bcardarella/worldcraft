"""Original tileable cooling-crust lava material; matches the runtime Metal field."""
import math

def smooth(a, b, x):
    t = min(1., max(0., (x-a)/(b-a)))
    return t*t*(3-2*t)

def field(u, v, time=0.):
    tau = math.tau
    x = u*8 + .48*math.sin(tau*v + time*.075) + .19*math.sin(tau*(u+v) - time*.041)
    y = v*8 + .48*math.sin(tau*u - time*.061) + .19*math.cos(tau*(u-v) + time*.035)
    ix, iy = math.floor(x), math.floor(y)
    first, second = 1e6, 1e6
    for j in range(-1,2):
        for i in range(-1,2):
            cx,cy=ix+i,iy+j
            h=math.sin((cx%8)*127.1+(cy%8)*311.7)*43758.5453
            a=h-math.floor(h)
            h=math.sin((cx%8)*269.5+(cy%8)*183.3)*43758.5453
            b=h-math.floor(h)
            d=(cx+.2+a*.6-x)**2+(cy+.2+b*.6-y)**2
            if d < first: second, first=first,d
            elif d < second: second=d
    edge=math.sqrt(second)-math.sqrt(first)
    crack=1-smooth(.018,.115,edge)
    flow=.5+.5*math.sin(tau*(u*3-v*2)+time*.19+math.sin(tau*v*4))
    upwelling=max(0.,flow-.35)**3*(1-smooth(.02,.12,first))
    heat=min(1.,crack*(.68+.32*flow)+upwelling)
    wrinkle=math.sin(tau*(u*37+v*19)+math.sin(tau*v*7)*2)
    relief=(1-crack)*(.35+.10*wrinkle)+heat*.035
    return relief,heat,crack,wrinkle

def images(size=256, time=0.):
    names=['LavaSurface.png','LavaEmission.png','LavaNormals.png','LavaRoughness.png']
    output={name:bytearray() for name in names}
    step=1/size
    for y in range(size):
        for x in range(size):
            u,v=x/size,y/size
            height,heat,crack,wrinkle=field(u,v,time)
            crust=(.045+wrinkle*.008,.027+wrinkle*.005,.023+wrinkle*.004)
            color=tuple(c*(1-crack)+hot*crack for c,hot in zip(crust,(.32,.065,.009)))
            emission=(heat,heat**3*.28,heat**7*.014)
            dx=(field(u+step,v,time)[0]-height)*3.8
            dy=(field(u,v+step,time)[0]-height)*3.8
            length=math.sqrt(1+dx*dx+dy*dy)
            normal=(-dx/length*.5+.5,-dy/length*.5+.5,1/length*.5+.5)
            rough=.96*(1-crack)+.48*crack
            for name,values in zip(names,(color,emission,normal,(rough,rough,rough))):
                output[name].extend(int(min(1,max(0,c))*255) for c in values)
    return output
