const dvui = @import("dvui");
const Font = dvui.Font;
const Theme = dvui.Theme;

pub const family = "Inter";

const fonts: []const Font.Source = &.{
    .{ .family = Font.array(family), .bytes = @embedFile("inter_regular") },
    .{ .family = Font.array(family), .weight = .bold, .bytes = @embedFile("inter_semibold") },
};

pub fn veneer(dark: bool) Theme {
    var t = if (dark) Theme.builtin.adwaita_dark else Theme.builtin.adwaita_light;
    t.name = if (dark) "Veneer Dark" else "Veneer Light";
    t.embedded_fonts = fonts;
    t.font_body = .find(.{ .family = family });
    t.font_heading = .find(.{ .family = family, .weight = .bold });
    t.font_title = .find(.{ .family = family, .weight = .bold, .size = Font.DefaultSize + 4 });
    t.font_mono = .find(.{ .family = family });
    t.corner = .round(8);
    return t;
}
