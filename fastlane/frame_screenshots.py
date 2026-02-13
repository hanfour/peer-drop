#!/usr/bin/env python3
"""
Custom screenshot framing script for PeerDrop.
Adds colored background and localized title text to App Store screenshots.
"""

import os
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

# Configuration
BACKGROUND_COLORS = {
    'light': '#007AFF',  # Brand blue
    'dark': '#1C1C1E'    # Dark mode
}

PADDING = 100
TITLE_PADDING = 80
FONT_SIZE = 72

# Localized titles for each screenshot
TITLES = {
    'en-US': {
        '01_NearbyTab': 'Discover Nearby Devices',
        '02_NearbyTabGrid': 'Grid View',
        '03_ConnectedTab': 'Active Connections',
        '04_ConnectionView': 'Connection Details',
        '05_ChatView': 'Secure Chat',
        '06_VoiceCallView': 'Voice Call',
        '07_LibraryTab': 'Device Library',
        '08_Settings': 'Settings',
        '09_QuickConnect': 'Quick Connect',
        '10_FileTransfer': 'File Transfer',
        '11_TransferHistory': 'Transfer History',
        '12_UserProfile': 'User Profile',
        '13_GroupDetail': 'Group Details',
    },
    'zh-Hant': {
        '01_NearbyTab': '發現附近裝置',
        '02_NearbyTabGrid': '網格檢視',
        '03_ConnectedTab': '已連接裝置',
        '04_ConnectionView': '連接詳情',
        '05_ChatView': '安全聊天',
        '06_VoiceCallView': '語音通話',
        '07_LibraryTab': '裝置資料庫',
        '08_Settings': '設定',
        '09_QuickConnect': '快速連接',
        '10_FileTransfer': '檔案傳輸',
        '11_TransferHistory': '傳輸紀錄',
        '12_UserProfile': '使用者資料',
        '13_GroupDetail': '群組詳情',
    },
    'zh-Hans': {
        '01_NearbyTab': '发现附近设备',
        '02_NearbyTabGrid': '网格视图',
        '03_ConnectedTab': '已连接设备',
        '04_ConnectionView': '连接详情',
        '05_ChatView': '安全聊天',
        '06_VoiceCallView': '语音通话',
        '07_LibraryTab': '设备库',
        '08_Settings': '设置',
        '09_QuickConnect': '快速连接',
        '10_FileTransfer': '文件传输',
        '11_TransferHistory': '传输记录',
        '12_UserProfile': '用户资料',
        '13_GroupDetail': '群组详情',
    },
    'ja': {
        '01_NearbyTab': '近くのデバイスを発見',
        '02_NearbyTabGrid': 'グリッド表示',
        '03_ConnectedTab': 'アクティブな接続',
        '04_ConnectionView': '接続の詳細',
        '05_ChatView': 'セキュアチャット',
        '06_VoiceCallView': '音声通話',
        '07_LibraryTab': 'デバイスライブラリ',
        '08_Settings': '設定',
        '09_QuickConnect': 'クイック接続',
        '10_FileTransfer': 'ファイル転送',
        '11_TransferHistory': '転送履歴',
        '12_UserProfile': 'ユーザープロフィール',
        '13_GroupDetail': 'グループ詳細',
    },
    'ko': {
        '01_NearbyTab': '주변 기기 발견',
        '02_NearbyTabGrid': '그리드 보기',
        '03_ConnectedTab': '활성 연결',
        '04_ConnectionView': '연결 상세',
        '05_ChatView': '보안 채팅',
        '06_VoiceCallView': '음성 통화',
        '07_LibraryTab': '기기 라이브러리',
        '08_Settings': '설정',
        '09_QuickConnect': '빠른 연결',
        '10_FileTransfer': '파일 전송',
        '11_TransferHistory': '전송 기록',
        '12_UserProfile': '사용자 프로필',
        '13_GroupDetail': '그룹 상세',
    },
}


def hex_to_rgb(hex_color):
    """Convert hex color to RGB tuple."""
    hex_color = hex_color.lstrip('#')
    return tuple(int(hex_color[i:i+2], 16) for i in (0, 2, 4))


def get_title_for_screenshot(filename, language):
    """Get the localized title for a screenshot."""
    # Extract the screenshot key from filename
    # e.g., "iPhone 17 Pro Max-01_NearbyTab.png" -> "01_NearbyTab"
    base = Path(filename).stem

    # Remove device prefix and _Dark suffix
    parts = base.split('-')
    if len(parts) >= 2:
        key = parts[-1]  # Get the last part after device name
    else:
        key = base

    # Remove _Dark suffix if present
    key = key.replace('_Dark', '')

    # Get titles for language, fallback to en-US
    lang_titles = TITLES.get(language, TITLES['en-US'])
    return lang_titles.get(key, '')


def get_font(size):
    """Get a font, falling back to default if needed."""
    # Try system fonts
    font_paths = [
        '/System/Library/Fonts/SFNS.ttf',  # SF Pro on macOS
        '/System/Library/Fonts/SFNSDisplay.ttf',
        '/System/Library/Fonts/Helvetica.ttc',
        '/Library/Fonts/Arial.ttf',
    ]

    for font_path in font_paths:
        if os.path.exists(font_path):
            try:
                return ImageFont.truetype(font_path, size)
            except:
                pass

    # Fallback to default
    return ImageFont.load_default()


def frame_screenshot(input_path, output_path, language):
    """Add background and title to a screenshot."""
    # Determine if dark mode
    is_dark = '_Dark' in input_path
    bg_color = hex_to_rgb(BACKGROUND_COLORS['dark'] if is_dark else BACKGROUND_COLORS['light'])

    # Load screenshot
    screenshot = Image.open(input_path)
    ss_width, ss_height = screenshot.size

    # Get title
    title = get_title_for_screenshot(input_path, language)

    # Calculate output dimensions
    output_width = ss_width + (PADDING * 2)
    title_height = TITLE_PADDING + FONT_SIZE + TITLE_PADDING if title else 0
    output_height = ss_height + title_height + PADDING

    # Create background
    output = Image.new('RGB', (output_width, output_height), bg_color)

    # Add title if present
    if title:
        draw = ImageDraw.Draw(output)
        font = get_font(FONT_SIZE)

        # Get text bounding box for centering
        bbox = draw.textbbox((0, 0), title, font=font)
        text_width = bbox[2] - bbox[0]
        text_x = (output_width - text_width) // 2
        text_y = TITLE_PADDING

        draw.text((text_x, text_y), title, fill='white', font=font)

    # Paste screenshot
    screenshot_x = PADDING
    screenshot_y = title_height
    output.paste(screenshot, (screenshot_x, screenshot_y))

    # Save
    output.save(output_path, 'PNG', optimize=True)
    return True


def process_screenshots(screenshots_dir):
    """Process all screenshots in the directory."""
    screenshots_path = Path(screenshots_dir)

    if not screenshots_path.exists():
        print(f"Error: Screenshots directory not found: {screenshots_dir}")
        return False

    processed = 0
    skipped = 0

    # Process each language directory
    for lang_dir in screenshots_path.iterdir():
        if not lang_dir.is_dir():
            continue

        language = lang_dir.name
        print(f"\nProcessing {language}...")

        # Find all PNG screenshots (excluding already framed ones)
        for screenshot_file in lang_dir.glob('*.png'):
            if '_framed' in screenshot_file.name:
                continue
            if 'background' in screenshot_file.name.lower():
                continue

            # Output path
            output_name = screenshot_file.stem + '_framed.png'
            output_path = screenshot_file.parent / output_name

            try:
                frame_screenshot(str(screenshot_file), str(output_path), language)
                print(f"  ✓ {screenshot_file.name}")
                processed += 1
            except Exception as e:
                print(f"  ✗ {screenshot_file.name}: {e}")
                skipped += 1

    print(f"\nDone! Processed: {processed}, Skipped: {skipped}")
    return True


if __name__ == '__main__':
    # Default to fastlane/screenshots if no argument provided
    if len(sys.argv) > 1:
        screenshots_dir = sys.argv[1]
    else:
        # Find the screenshots directory relative to this script
        script_dir = Path(__file__).parent
        screenshots_dir = script_dir / 'screenshots'

    process_screenshots(screenshots_dir)
