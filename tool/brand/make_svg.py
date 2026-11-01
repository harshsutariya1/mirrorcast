# Generates the MirrorCast artwork as SVG. One glyph, several framings.
import sys
GRAD = '''<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#7C83FF"/><stop offset="0.55" stop-color="#5B4CF0"/><stop offset="1" stop-color="#7A3FE0"/></linearGradient>
<linearGradient id="shine" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>
<linearGradient id="phoneScreen" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#6D6BFA"/><stop offset="1" stop-color="#6A3FE6"/></linearGradient>'''

def glyph(color="#FFFFFF", mono=False):
    # Designed on a 1024 grid, centred. A phone in front of a display that shows it.
    display = f'''
    <rect x="300" y="250" width="520" height="370" rx="46" fill="{color}" fill-opacity="{0 if mono else 0.14}" stroke="{color}" stroke-width="40"/>
    <rect x="470" y="664" width="180" height="34" rx="17" fill="{color}"/>
    <rect x="540" y="630" width="40" height="44" fill="{color}"/>
    <rect x="600" y="318" width="132" height="234" rx="22" fill="{color}" fill-opacity="{1 if mono else 0.55}"/>
    <path d="M 420 352 A 68 68 0 0 1 488 420" fill="none" stroke="{color}" stroke-width="28" stroke-linecap="round"/>
    <path d="M 420 288 A 132 132 0 0 1 552 420" fill="none" stroke="{color}" stroke-width="28" stroke-linecap="round"/>'''
    # Cut a gap around the phone so it reads as being in front.
    cut = '''<mask id="gap"><rect width="1024" height="1024" fill="white"/><rect x="176" y="396" width="244" height="408" rx="58" fill="black"/></mask>'''
    if mono:
        phone = f'''<rect x="210" y="430" width="176" height="340" rx="30" fill="none" stroke="{color}" stroke-width="20"/>
    <circle cx="298" cy="458" r="9" fill="{color}"/>'''
    else:
        phone = f'''<rect x="200" y="420" width="196" height="360" rx="40" fill="{color}"/>
    <rect x="220" y="452" width="156" height="296" rx="22" fill="url(#phoneScreen)"/>
    <circle cx="298" cy="436" r="7" fill="url(#phoneScreen)"/>'''
    return f'''<defs>{cut}</defs><g mask="url(#gap)">{display}</g>{phone}'''

def doc(kind):
    if kind == "mac":       # Big Sur grid: 824px body, 100px margin, soft shadow
        body = f'''<filter id="sh" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#1B1240" flood-opacity="0.35"/></filter>
  <g filter="url(#sh)"><rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/></g>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#shine)"/>
  <g transform="translate(512 512) scale(0.86) translate(-512 -515)">{glyph()}</g>'''
    elif kind == "square":  # full-bleed rounded square (in-app logo, legacy launcher)
        body = f'''<rect width="1024" height="1024" rx="230" fill="url(#bg)"/><rect width="1024" height="1024" rx="230" fill="url(#shine)"/>
  <g transform="translate(512 512) scale(1.0) translate(-512 -515)">{glyph()}</g>'''
    elif kind == "fg":      # adaptive foreground: glyph inside the 66/108 safe zone, transparent
        body = f'<g transform="translate(512 512) scale(0.62) translate(-512 -515)">{glyph()}</g>'
    elif kind == "mono":    # themed (monochrome) icon: white glyph, screens cut out
        body = f'''<g transform="translate(512 512) scale(0.62) translate(-512 -515)">{glyph("#FFFFFF", mono=True)}</g>'''
    elif kind == "bg":
        body = '<rect width="1024" height="1024" fill="url(#bg)"/>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><defs>{GRAD}</defs>{body}</svg>'

for kind in ["mac", "square", "fg", "mono", "bg"]:
    open(f"{kind}.svg", "w").write(doc(kind))
