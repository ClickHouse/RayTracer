#!/usr/bin/env python3
"""Design "ClickHouse" from three CSG solid types:
   - obox  : oriented box / parallelepiped (cx,cz,hx,hz,theta)  -> straight & angled strokes
   - ring  : annulus = outer cylinder MINUS inner cylinder, optionally MINUS a cut box
             (cx,cz,Ro,Ri, cut)   cut = None or (rx0,rz0,rx1,rz1)   -> round letters / arcs
   - sphere: (cx,cz,r)                                            -> the dot on i
Local coords: x right, z up, baseline z=0, cap height 7, x-height ~5."""
import math, sys

HW = 0.62   # stroke half-width / cylinder radius

# Straight strokes are round cylinders (rods) between two points, radius r.
def vbox(cx, z0, z1, r=HW):      return ('cyl', cx, z0, cx, z1, r)
def hbox(z, x0, x1, r=HW):       return ('cyl', x0, z, x1, z, r)
def abox(x0, z0, x1, z1, r=HW):  return ('cyl', x0, z0, x1, z1, r)

G = {}
G['C'] = (5.6, [('torus', 2.85, 2.9, 2.9, 1.66, (2.95, 1.4, 9.0, 4.4))])
G['l'] = (1.9, [vbox(0.7, 0.0, 7.0)])
G['i'] = (1.9, [vbox(0.7, 0.0, 5.0), ('sphere', 0.7, 6.3, 0.72)])
G['c'] = (4.3, [('torus', 2.1, 2.0, 2.0, 0.85, (2.2, 1.06, 9.0, 2.94))])
G['k'] = (4.6, [vbox(0.65, 0.0, 7.0), abox(1.0, 2.5, 3.9, 5.1), abox(1.2, 2.6, 3.9, 0.0)])
G['H'] = (5.3, [vbox(0.65, 0.0, 7.0), vbox(4.4, 0.0, 7.0), hbox(3.5, 0.6, 4.4)])
G['o'] = (4.9, [('torus', 2.35, 2.0, 2.0, 0.95, None)])
# u: verticals sit exactly at the arc's tube centerline (cx +- R) and overlap it,
# and the arc's tube radius equals the cylinder radius, so they join seamlessly
G['u'] = (4.9, [vbox(0.87, 1.0, 5.0), vbox(3.77, 1.0, 5.0),
                ('torus', 2.32, 1.5, 2.07, 0.83, (-9.0, 1.5, 9.0, 9.0))])
# s = two c-like arcs: top opens lower-right, bottom opens upper-left
G['s'] = (4.2, [('torus', 2.05, 3.5, 1.45, 0.6, (2.05, -9.0, 9.0, 3.5)),
                ('torus', 2.05, 1.4, 1.45, 0.6, (-9.0, 1.4, 2.05, 9.0))])
# e = torus + a horizontal cylinder bar. The opening is a thin horizontal slab
# cut just below the bar (z in [1.5, 2.14], right of x=2.5): it detaches the
# bar from the lower stroke without removing the bottom-right corner, so the
# bottom handle continues to the right but does not reconnect to the bar.
G['e'] = (4.5, [('torus', 2.2, 2.05, 2.05, 1.12, (2.5, 1.05, 9.0, 1.69)),
                hbox(2.10, 0.3, 3.8, HW / 1.5)])

WORD, GAP = "ClickHouse", 1.0

def layout(word):
    prims, x = [], 0.0
    for ch in word:
        w, ps = G[ch]
        for p in ps:
            if p[0] == 'obox':
                prims.append(('obox', p[1]+x, p[2], p[3], p[4], p[5]))
            elif p[0] == 'cyl':
                prims.append(('cyl', p[1]+x, p[2], p[3]+x, p[4], p[5]))
            elif p[0] in ('ring', 'torus'):
                cut = p[5]
                cut2 = None if cut is None else (cut[0]+x, cut[1], cut[2]+x, cut[3])
                prims.append((p[0], p[1]+x, p[2], p[3], p[4], cut2))
            else:
                prims.append(('sphere', p[1]+x, p[2], p[3]))
        x += w + GAP
    return prims, x - GAP

PRIMS, TOTAL_W = layout(WORD)

def inside(px, pz):
    for p in PRIMS:
        if p[0] == 'obox':
            _, cx, cz, hx, hz, th = p
            t = math.radians(th)
            lx =  (px-cx)*math.cos(t) + (pz-cz)*math.sin(t)
            lz = -(px-cx)*math.sin(t) + (pz-cz)*math.cos(t)
            if abs(lx) <= hx and abs(lz) <= hz: return True
        elif p[0] == 'cyl':
            _, x0, z0, x1, z1, r = p
            dx, dz = x1-x0, z1-z0
            L2 = dx*dx + dz*dz
            tt = 0.0 if L2 == 0 else ((px-x0)*dx + (pz-z0)*dz) / L2
            if 0.0 <= tt <= 1.0:
                cxp, czp = x0 + tt*dx, z0 + tt*dz
                if math.hypot(px-cxp, pz-czp) <= r: return True
        elif p[0] in ('ring', 'torus'):   # same x-z footprint (annulus)
            _, cx, cz, Ro, Ri, cut = p
            r = math.hypot(px-cx, pz-cz)
            if Ri <= r <= Ro:
                if cut is None or not (cut[0] <= px <= cut[2] and cut[1] <= pz <= cut[3]):
                    return True
        else:
            _, cx, cz, rad = p
            if math.hypot(px-cx, pz-cz) <= rad: return True
    return False

def preview():
    step = 0.17
    z = 7.6
    while z >= -0.5:
        line = "".join("@" if inside(x, z) else " " for x in
                       [(-0.5 + i*step) for i in range(int((TOTAL_W+1.0)/step))])
        print(line)
        z -= step*2.0
    nb = sum(1 for p in PRIMS if p[0]=='obox')
    nc = sum(1 for p in PRIMS if p[0]=='cyl')
    nr = sum(1 for p in PRIMS if p[0]=='ring')
    ns = sum(1 for p in PRIMS if p[0]=='sphere')
    print(f"\nwidth={TOTAL_W:.1f}  obox={nb} cyl={nc} ring={nr} sphere={ns}")

if __name__ == '__main__':
    preview()
