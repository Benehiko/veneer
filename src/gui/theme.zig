const dvui = @import("dvui");
const Color = dvui.Color;
const Font = dvui.Font;
const Theme = dvui.Theme;

pub const ground = Color{ .r = 0x0b, .g = 0x0a, .b = 0x1c };
pub const raised = Color{ .r = 0x17, .g = 0x15, .b = 0x3a };
pub const text = Color{ .r = 0xec, .g = 0xeb, .b = 0xff };
pub const accent = Color{ .r = 0xff, .g = 0x2b, .b = 0xd6 };
pub const accent_lit = Color{ .r = 0xff, .g = 0x7a, .b = 0xe6 };
pub const accent_dim = Color{ .r = 0xc2, .g = 0x00, .b = 0x8f };
pub const neon = Color{ .r = 0x22, .g = 0xe4, .b = 0xff };
pub const coin = Color{ .r = 0xff, .g = 0xe1, .b = 0x4d };
pub const muted = Color{ .r = 0x98, .g = 0x96, .b = 0xc8 };
pub const rule = Color{ .r = 0x2e, .g = 0x2b, .b = 0x66 };
const rule_lit = Color{ .r = 0x3d, .g = 0x39, .b = 0x85 };
const rule_hot = Color{ .r = 0x4c, .g = 0x47, .b = 0xa3 };
const raised_lit = Color{ .r = 0x21, .g = 0x1e, .b = 0x50 };
const danger = Color{ .r = 0xff, .g = 0x3b, .b = 0x5c };
const danger_lit = Color{ .r = 0xff, .g = 0x6b, .b = 0x84 };
const danger_dim = Color{ .r = 0xd6, .g = 0x1f, .b = 0x40 };

const body = "Chakra Petch";
const pixel = "Press Start 2P";
const mono = "VT323";

const fonts: []const Font.Source = &.{
    .{ .family = Font.array(body), .bytes = @embedFile("chakra_regular") },
    .{ .family = Font.array(body), .weight = .bold, .bytes = @embedFile("chakra_semibold") },
    .{ .family = Font.array(pixel), .bytes = @embedFile("press_start_2p") },
    .{ .family = Font.array(mono), .bytes = @embedFile("vt323") },
};

pub fn veneer() Theme {
    return .{
        .name = "Veneer Arcade",
        .dark = true,
        .embedded_fonts = fonts,

        .font_body = .find(.{ .family = body, .size = Font.DefaultSize + 1 }),
        .font_heading = .find(.{ .family = body, .weight = .bold, .size = Font.DefaultSize + 1 }),
        .font_title = .find(.{ .family = pixel, .size = 14 }),
        .font_mono = .find(.{ .family = mono, .size = Font.DefaultSize + 4 }),

        .corner = .square,

        .focus = neon,
        .text_select = accent_dim,

        .fill = raised,
        .fill_hover = raised_lit,
        .fill_press = rule,
        .text = text,
        .border = rule,

        .window = .{ .fill = ground },

        .control = .{
            .fill = rule,
            .fill_hover = rule_lit,
            .fill_press = rule_hot,
            .text = text,
            .text_hover = neon,
            .text_press = neon,
            .border = rule_hot,
        },

        .highlight = .{
            .fill = accent,
            .fill_hover = accent_lit,
            .fill_press = accent_dim,
            .text = ground,
            .border = accent_lit,
        },

        .err = .{
            .fill = danger,
            .fill_hover = danger_lit,
            .fill_press = danger_dim,
            .text = ground,
            .border = danger_lit,
        },

        .app1 = .{ .text = coin },
        .app2 = .{ .text = neon },
        .app3 = .{ .text = muted },
    };
}
