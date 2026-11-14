import os
import json
from PIL import Image, ImageDraw

def main():
    logo_path = 'logo_vampior.png'
    if not os.path.exists(logo_path):
        print("ERROR: logo_vampior.png not found!")
        return

    logo = Image.open(logo_path).convert('RGBA')

    # ==================== 1. iOS AppIcon ====================
    ios_dir = 'ios/HorusEyes/Assets.xcassets/AppIcon.appiconset'
    os.makedirs(ios_dir, exist_ok=True)

    # 1024x1024 Universal (RGB mode, no alpha as required by App Store / iOS)
    icon_1024 = logo.convert('RGB').resize((1024, 1024), Image.Resampling.LANCZOS)
    icon_1024.save(os.path.join(ios_dir, 'AppIcon-1024.png'), 'PNG')

    ios_sizes = [
        ('AppIcon-20x20@2x.png', 40),
        ('AppIcon-20x20@3x.png', 60),
        ('AppIcon-29x29@2x.png', 58),
        ('AppIcon-29x29@3x.png', 87),
        ('AppIcon-40x40@2x.png', 80),
        ('AppIcon-40x40@3x.png', 120),
        ('AppIcon-60x60@2x.png', 120),
        ('AppIcon-60x60@3x.png', 180),
    ]

    for filename, size in ios_sizes:
        img = logo.convert('RGB').resize((size, size), Image.Resampling.LANCZOS)
        img.save(os.path.join(ios_dir, filename), 'PNG')

    contents_dict = {
        "images": [
            {"filename": "AppIcon-20x20@2x.png", "idiom": "iphone", "scale": "2x", "size": "20x20"},
            {"filename": "AppIcon-20x20@3x.png", "idiom": "iphone", "scale": "3x", "size": "20x20"},
            {"filename": "AppIcon-29x29@2x.png", "idiom": "iphone", "scale": "2x", "size": "29x29"},
            {"filename": "AppIcon-29x29@3x.png", "idiom": "iphone", "scale": "3x", "size": "29x29"},
            {"filename": "AppIcon-40x40@2x.png", "idiom": "iphone", "scale": "2x", "size": "40x40"},
            {"filename": "AppIcon-40x40@3x.png", "idiom": "iphone", "scale": "3x", "size": "40x40"},
            {"filename": "AppIcon-60x60@2x.png", "idiom": "iphone", "scale": "2x", "size": "60x60"},
            {"filename": "AppIcon-60x60@3x.png", "idiom": "iphone", "scale": "3x", "size": "60x60"},
            {"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        ],
        "info": {
            "author": "xcode",
            "version": 1
        }
    }

    with open(os.path.join(ios_dir, 'Contents.json'), 'w', encoding='utf-8') as f:
        json.dump(contents_dict, f, indent=2)

    xcassets_dir = 'ios/HorusEyes/Assets.xcassets'
    with open(os.path.join(xcassets_dir, 'Contents.json'), 'w', encoding='utf-8') as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)

    print("iOS AppIcon assets generated.")

    # ==================== 2. Android Icons ====================
    android_res = 'android/app/src/main/res'
    densities = {
        'mipmap-mdpi': (48, 108),
        'mipmap-hdpi': (72, 162),
        'mipmap-xhdpi': (96, 216),
        'mipmap-xxhdpi': (144, 324),
        'mipmap-xxxhdpi': (192, 432),
    }

    for folder, (std_size, fg_size) in densities.items():
        dpath = os.path.join(android_res, folder)
        os.makedirs(dpath, exist_ok=True)

        # 1. Standard launcher icon
        std_img = logo.convert('RGB').resize((std_size, std_size), Image.Resampling.LANCZOS)
        std_img.save(os.path.join(dpath, 'ic_launcher.png'), 'PNG')

        # 2. Round launcher icon
        round_img = Image.new('RGBA', (std_size, std_size), (0, 0, 0, 0))
        mask = Image.new('L', (std_size, std_size), 0)
        draw = ImageDraw.Draw(mask)
        draw.ellipse((0, 0, std_size - 1, std_size - 1), fill=255)
        round_img.paste(std_img, (0, 0), mask=mask)
        round_img.save(os.path.join(dpath, 'ic_launcher_round.png'), 'PNG')

        # 3. Adaptive foreground icon (centered within safe zone)
        fg_canvas = Image.new('RGBA', (fg_size, fg_size), (0, 0, 0, 0))
        inner_size = int(fg_size * 0.72)
        inner_logo = logo.resize((inner_size, inner_size), Image.Resampling.LANCZOS)
        offset = (fg_size - inner_size) // 2
        fg_canvas.paste(inner_logo, (offset, offset), mask=inner_logo)
        fg_canvas.save(os.path.join(dpath, 'ic_launcher_foreground.png'), 'PNG')

    # Adaptive XMLs
    anydpi_dir = os.path.join(android_res, 'mipmap-anydpi-v26')
    os.makedirs(anydpi_dir, exist_ok=True)

    adaptive_xml = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
'''
    with open(os.path.join(anydpi_dir, 'ic_launcher.xml'), 'w', encoding='utf-8') as f:
        f.write(adaptive_xml)
    with open(os.path.join(anydpi_dir, 'ic_launcher_round.xml'), 'w', encoding='utf-8') as f:
        f.write(adaptive_xml)

    # Background color
    colors_path = os.path.join(android_res, 'values', 'colors.xml')
    colors_content = '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="black">#FF000000</color>
    <color name="white">#FFFFFFFF</color>
    <color name="hud_bg">#B00A0A0A</color>
    <color name="accent_green">#00E676</color>
    <color name="warning_orange">#FF9100</color>
    <color name="critical_red">#FF1744</color>
    <color name="ic_launcher_background">#D4D2D3</color>
</resources>
'''
    with open(colors_path, 'w', encoding='utf-8') as f:
        f.write(colors_content)

    print("Android launcher icon assets generated.")

if __name__ == '__main__':
    main()
