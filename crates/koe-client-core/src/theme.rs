//! Shared light surfaces, charcoal accent and native typography tokens.

pub use koe_engine::domain::EditorialCardRole;

/// Colors of the approved desktop design (`0xAARRGGBB`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppColors;

impl AppColors {
    /// Window canvas.
    pub const CANVAS: u32 = 0xFFFFFFFF;
    /// Sidebar surface.
    pub const SIDEBAR: u32 = 0xFFF7F7F8;
    /// Primary page surface.
    pub const SURFACE_0: u32 = 0xFFFFFFFF;
    /// Sidebar surface.
    pub const BG_PANEL: u32 = 0xFFF7F7F8;
    /// Elevated content surface.
    pub const SURFACE_1: u32 = 0xFFFFFFFF;
    /// Card surface.
    pub const BG_CARD: u32 = 0xFFFFFFFF;
    /// Subtle control surface.
    pub const BG_SUBTLE: u32 = 0xFFF1F1F3;
    /// Hover surface.
    pub const BG_CARD_HOVER: u32 = 0xFFECECEF;
    /// Muted surface.
    pub const BG_MUTED: u32 = 0xFFF1F1F3;
    /// Standard divider.
    pub const BORDER: u32 = 0xFFE3E3E7;
    /// Soft divider.
    pub const BORDER_SOFT: u32 = 0xFFEBEBEE;
    /// Strong divider.
    pub const BORDER_STRONG: u32 = 0xFFCDCDD3;
    /// Selected border.
    pub const BORDER_SELECTED: u32 = 0xFF242426;
    /// Primary text.
    pub const TEXT_PRIMARY: u32 = 0xFF202022;
    /// Secondary text.
    pub const TEXT_SECONDARY: u32 = 0xFF54545B;
    /// Muted text, with readable contrast on all surfaces.
    pub const TEXT_MUTED: u32 = 0xFF686870;
    /// Charcoal action fill and link text.
    pub const ACCENT: u32 = 0xFF242426;
    /// Hovered action fill.
    pub const ACCENT_HOVER: u32 = 0xFF39393C;
    /// Selected navigation surface.
    pub const ACCENT_SOFT: u32 = 0xFFECECEF;
    /// Selected navigation border.
    pub const ACCENT_BORDER: u32 = 0xFFCDCDD3;
    /// Foreground on the charcoal action fill.
    pub const ON_ACCENT: u32 = 0xFFFFFFFF;
    /// Unplayed waveform.
    pub const WAVE_UNPLAYED: u32 = 0xFF93939B;
    /// Success text.
    pub const SUCCESS: u32 = 0xFF287447;
    /// Success surface.
    pub const SUCCESS_SOFT: u32 = 0xFFEDF5EF;
    /// Warning text.
    pub const WARNING: u32 = 0xFF8A5A12;
    /// Warning surface.
    pub const WARNING_SOFT: u32 = 0xFFFAF3E7;
    /// Error text.
    pub const DANGER: u32 = 0xFFB43D43;
    /// Error surface.
    pub const DANGER_SOFT: u32 = 0xFFFBEEEE;
    /// Information text.
    pub const INFO: u32 = 0xFF326985;
    /// Information surface.
    pub const INFO_SOFT: u32 = 0xFFEDF4F8;
    /// Flat content cards have no shadow.
    pub const CARD_SHADOW: &[u32] = &[];

    /// Removes the alpha byte.
    #[must_use]
    pub const fn rgb24(argb: u32) -> u32 {
        argb & 0x00FF_FFFF
    }
}

/// Colors for an editorial role when displayed as a card.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EditorialRolePalette {
    /// Background.
    pub bg: u32,
    /// Border.
    pub border: u32,
    /// Role label text.
    pub badge_text: u32,
}

/// Semantic role colors share the desktop's light surfaces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AIVisualEditorialPalette;

impl AIVisualEditorialPalette {
    /// Returns the role's accessible light surface palette.
    #[must_use]
    pub const fn for_role(role: EditorialCardRole) -> EditorialRolePalette {
        let (bg, badge_text) = match role {
            EditorialCardRole::ConclusionAmber | EditorialCardRole::TakeawaysPlum => {
                (AppColors::ACCENT_SOFT, AppColors::ACCENT)
            }
            EditorialCardRole::ActionsBlue => (AppColors::SUCCESS_SOFT, AppColors::SUCCESS),
            EditorialCardRole::RisksCoral => (AppColors::DANGER_SOFT, AppColors::DANGER),
            EditorialCardRole::FlowEmerald => (AppColors::WARNING_SOFT, AppColors::WARNING),
            EditorialCardRole::QuestionsSlate => (AppColors::INFO_SOFT, AppColors::INFO),
        };
        EditorialRolePalette {
            bg,
            border: AppColors::BORDER_STRONG,
            badge_text,
        }
    }
}

/// Native text sizes in points.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AppFontSizes;
impl AppFontSizes {
    /// Metadata.
    pub const XS: f32 = 12.0;
    /// Body and control.
    pub const SM: f32 = 14.0;
    /// Section heading.
    pub const MD: f32 = 16.0;
    /// Page title.
    pub const LG: f32 = 22.0;
}

/// Native rounded corner sizes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AppRadii;
impl AppRadii {
    /// Outer container.
    pub const OUTER: f32 = 12.0;
    /// Content card.
    pub const CARD: f32 = 10.0;
    /// Control.
    pub const CONTROL: f32 = 6.0;
    /// Computes a concentric inner radius.
    #[must_use]
    pub const fn concentric(outer: f32, padding: f32) -> f32 {
        let inner = outer - padding;
        if inner > 4.0 {
            inner
        } else {
            4.0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn contrast(a: u32, b: u32) -> f64 {
        fn luminance(value: u32) -> f64 {
            let channel = |shift: u32| {
                let v = f64::from(((value >> shift) & 255) as u8) / 255.0;
                if v <= 0.03928 {
                    v / 12.92
                } else {
                    ((v + 0.055) / 1.055).powf(2.4)
                }
            };
            0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let a = luminance(a);
        let b = luminance(b);
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }
    #[test]
    fn text_is_readable_on_every_shared_surface() {
        assert!(contrast(AppColors::ACCENT, AppColors::ON_ACCENT) >= 4.5);
        for surface in [
            AppColors::SURFACE_0,
            AppColors::SURFACE_1,
            AppColors::BG_PANEL,
        ] {
            for text in [
                AppColors::TEXT_PRIMARY,
                AppColors::TEXT_SECONDARY,
                AppColors::TEXT_MUTED,
            ] {
                assert!(contrast(surface, text) >= 4.5);
            }
        }
        for role in [
            EditorialCardRole::ConclusionAmber,
            EditorialCardRole::ActionsBlue,
            EditorialCardRole::RisksCoral,
            EditorialCardRole::FlowEmerald,
            EditorialCardRole::QuestionsSlate,
            EditorialCardRole::TakeawaysPlum,
        ] {
            let palette = AIVisualEditorialPalette::for_role(role);
            assert!(contrast(palette.bg, AppColors::TEXT_PRIMARY) >= 7.0);
            assert!(contrast(palette.bg, palette.badge_text) >= 4.5);
        }
    }
}
