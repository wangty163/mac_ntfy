//
//  EmojiMap.swift
//  NtfyMac
//
//  ntfy maps certain tags to emoji using GitHub-style shortcodes. This is a
//  curated subset covering the most common notification tags; unknown tags are
//  rendered as plain text chips instead.
//

import Foundation

enum EmojiMap {
    static func emoji(for tag: String) -> String? {
        table[tag.lowercased()]
    }

    private static let table: [String: String] = [
        // status / severity
        "warning": "⚠️", "white_check_mark": "✅", "heavy_check_mark": "✔️",
        "x": "❌", "no_entry": "⛔", "no_entry_sign": "🚫",
        "rotating_light": "🚨", "skull": "💀", "skull_and_crossbones": "☠️",
        "fire": "🔥", "boom": "💥", "zap": "⚡", "bangbang": "‼️",
        "exclamation": "❗", "question": "❓", "interrobang": "⁉️",
        "sos": "🆘", "ok": "🆗", "100": "💯", "checkered_flag": "🏁",
        // tech / infra
        "computer": "💻", "desktop_computer": "🖥️", "iphone": "📱",
        "cd": "💿", "floppy_disk": "💾", "package": "📦", "gear": "⚙️",
        "wrench": "🔧", "hammer": "🔨", "hammer_and_wrench": "🛠️",
        "lock": "🔒", "unlock": "🔓", "key": "🔑", "shield": "🛡️",
        "satellite": "📡", "battery": "🔋", "electric_plug": "🔌",
        "globe_with_meridians": "🌐", "link": "🔗", "wifi": "📶",
        "robot": "🤖", "bug": "🐛", "rocket": "🚀", "satellite_antenna": "📡",
        // money / commerce
        "moneybag": "💰", "money_with_wings": "💸", "dollar": "💵",
        "credit_card": "💳", "chart_with_upwards_trend": "📈",
        "chart_with_downwards_trend": "📉", "shopping_cart": "🛒",
        // communication
        "email": "📧", "envelope": "✉️", "incoming_envelope": "📨",
        "telephone": "☎️", "phone": "📞", "bell": "🔔", "no_bell": "🔕",
        "loudspeaker": "📢", "mega": "📣", "speech_balloon": "💬",
        "calendar": "📅", "date": "📆", "alarm_clock": "⏰", "hourglass": "⌛",
        "clock": "🕐", "stopwatch": "⏱️",
        // people / reactions
        "tada": "🎉", "partying_face": "🥳", "trophy": "🏆", "medal": "🏅",
        "thumbsup": "👍", "+1": "👍", "thumbsdown": "👎", "-1": "👎",
        "clap": "👏", "wave": "👋", "pray": "🙏", "muscle": "💪",
        "eyes": "👀", "thinking": "🤔", "see_no_evil": "🙈",
        "heart": "❤️", "broken_heart": "💔", "sparkling_heart": "💖",
        "smile": "😄", "grinning": "😀", "sob": "😭", "cry": "😢",
        "rage": "😡", "scream": "😱", "sweat": "😓", "ghost": "👻",
        // nature / weather
        "sunny": "☀️", "cloud": "☁️", "rain": "🌧️", "snowflake": "❄️",
        "zap_weather": "🌩️", "umbrella": "☔", "thermometer": "🌡️",
        "star": "⭐", "star2": "🌟", "sparkles": "✨", "rainbow": "🌈",
        "droplet": "💧", "ocean": "🌊", "leaves": "🍃", "deciduous_tree": "🌳",
        // misc objects
        "bulb": "💡", "flashlight": "🔦", "mag": "🔍", "mag_right": "🔎",
        "bookmark": "🔖", "pushpin": "📌", "paperclip": "📎", "pencil": "✏️",
        "memo": "📝", "page_facing_up": "📄", "clipboard": "📋",
        "file_folder": "📁", "open_file_folder": "📂", "books": "📚",
        "newspaper": "📰", "camera": "📷", "video_camera": "📹",
        "movie_camera": "🎥", "art": "🎨", "musical_note": "🎵",
        "headphones": "🎧", "microphone": "🎤", "game_die": "🎲",
        "dart": "🎯", "gift": "🎁", "balloon": "🎈", "crown": "👑",
        "gem": "💎", "hourglass_flowing_sand": "⏳",
        // food
        "coffee": "☕", "beer": "🍺", "pizza": "🍕", "hamburger": "🍔",
        "cake": "🍰", "birthday": "🎂", "apple": "🍎", "cookie": "🍪",
        // transport
        "car": "🚗", "truck": "🚚", "airplane": "✈️", "ship": "🚢",
        "train": "🚆", "bike": "🚲", "construction": "🚧", "traffic_light": "🚦",
        // hands / signs
        "point_up": "☝️", "point_right": "👉", "raised_hand": "✋",
        "ok_hand": "👌", "v": "✌️", "metal": "🤘", "facepunch": "👊",
    ]
}
