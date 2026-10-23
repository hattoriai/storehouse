# The Exif fixtures, from harbour.jpg, with Pillow: python3 make.py ../harbour.jpg
import sys
from PIL import Image, ImageCms
src = sys.argv[1]
im = Image.open(src).convert("RGB").resize((96, 64))
def exif(model):
    e = Image.Exif()
    e[0x010F] = "Maker"; e[0x0110] = model; e[0x0112] = 6; e[0x013B] = "Old Name"; e[0x8298] = "Old Copyright"
    e[0x0131] = "Firmware 1.0"
    ex = e.get_ifd(0x8769); ex[0x9003] = "2026:10:01 10:00:00"; ex[0x829D] = (28, 10); ex[0x8827] = 200; ex[0x927C] = b"MAKERNOTE-blob-1234567890"
    g = e.get_ifd(0x8825); g[1] = "N"; g[2] = (41.0, 8.0, 30.0); g[3] = "W"; g[4] = (8.0, 37.0, 12.5)
    return e
xmp = b'<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/" exif:GPSLatitude="41,8.5N" exif:GPSLongitude=\'8,37.2W\'><exif:GPSAltitude>120/1</exif:GPSAltitude><exif:GPSVersionID/><dc:creator><rdf:Seq><rdf:li>Someone</rdf:li></rdf:Seq></dc:creator></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>'
icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
im.save("camera.jpg", exif=exif("Camera One"), quality=90)
im.save("phone.jpg", exif=exif("Phone Two"), xmp=xmp, icc_profile=icc, progressive=True, quality=85)

