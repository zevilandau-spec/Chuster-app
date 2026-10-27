import datetime
def leap(y): return (7*y+1)%19 < 7
def last_month(y): return 13 if leap(y) else 12
def elapsed(y):
    me = 235*((y-1)//19) + 12*((y-1)%19) + (7*((y-1)%19)+1)//19
    pe = 204 + 793*(me%1080)
    he = 5 + 12*me + 793*(me//1080) + pe//1080
    cd = 1 + 29*me + he//24
    cp = 1080*(he%24) + pe%1080
    if cp>=19440 or (cd%7==2 and cp>=9924 and not leap(y)) or (cd%7==1 and cp>=16789 and leap(y-1)):
        ad=cd+1
    else: ad=cd
    if ad%7 in (0,3,5): ad+=1
    return ad
def ydays(y): return elapsed(y+1)-elapsed(y)
def mdays(m,y):
    if m in (2,4,6,10,13): return 29
    if m==12 and not leap(y): return 29
    if m==8 and ydays(y)%10!=5: return 29
    if m==9 and ydays(y)%10==3: return 29
    return 30
EPOCH=-1373429
def to_abs(m,d,y):
    s=d
    if m<7:
        for mm in range(7,last_month(y)+1): s+=mdays(mm,y)
        for mm in range(1,m): s+=mdays(mm,y)
    else:
        for mm in range(7,m): s+=mdays(mm,y)
    return s+elapsed(y)+EPOCH
def from_abs(a):
    y=(a+1373429)//366
    while a>=to_abs(7,1,y+1): y+=1
    start = 7 if a>=to_abs(1,1,y) else 1
    # iterate months in order from Tishrei
    order=list(range(7,last_month(y)+1))+list(range(1,7))
    for m in order:
        if a<=to_abs(m,mdays(m,y),y):
            return m,a-to_abs(m,1,y)+1,y
NAMES={1:'Nisan',2:'Iyar',3:'Sivan',4:'Tammuz',5:'Av',6:'Elul',7:'Tishrei',8:'Cheshvan',9:'Kislev',10:'Tevet',11:'Shevat',12:'Adar',13:'Adar II'}
def name(m,y):
    if leap(y) and m==12: return 'Adar I'
    return NAMES[m]
