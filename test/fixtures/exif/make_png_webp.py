# The PNG and WebP fixtures, from harbour.jpg, with Pillow:
# python3 make_png_webp.py ../harbour.jpg
import sys
from PIL import Image, ImageCms, PngImagePlugin

src = Image.open(sys.argv[1]).convert("RGB").resize((48, 32))
alpha = src.convert("RGBA")
alpha.putalpha(200)

def exif():
    e = Image.Exif()
    e[0x010F] = "Maker"; e[0x0110] = "Phone Two"; e[0x0112] = 1
    e[0x013B] = "Old Name"; e[0x8298] = "Old Copyright"
    ex = e.get_ifd(0x8769); ex[0x9003] = "2026:10:01 10:00:00"; ex[0x8827] = 200
    g = e.get_ifd(0x8825); g[1] = "N"; g[2] = (41.0, 8.0, 30.0); g[3] = "W"; g[4] = (8.0, 37.0, 12.5)
    return e

xmp = ('<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
       '<rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"'
       ' exif:GPSLatitude="41,8.5N"><exif:GPSAltitude>120/1</exif:GPSAltitude>'
       '<dc:creator><rdf:Seq><rdf:li>Someone</rdf:li></rdf:Seq></dc:creator></rdf:Description></rdf:RDF></x:xmpmeta>')
icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()

info = PngImagePlugin.PngInfo()
info.add_text("Author", "Old Name")
info.add_text("Comment", "a comment", zip=True)
info.add_itxt("XML:com.adobe.xmp", xmp, zip=True)
alpha.save("photo.png", exif=exif(), pnginfo=info, icc_profile=icc)

frames = [src, src.rotate(180)]
frames[0].save("animated.png", save_all=True, append_images=frames[1:], exif=exif(), duration=100)

src.save("photo.webp", exif=exif(), xmp=xmp.encode(), icc_profile=icc, quality=80)
alpha.save("simple.webp", lossless=True)
frames[0].save("animated.webp", save_all=True, append_images=frames[1:], exif=exif(), duration=100)
