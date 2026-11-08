#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppColors;

impl AppColors {
    /// Traditional Chinese Bamboo Green primary accent (`#2E5E4E`, contrast `7.42:1` on white).
    pub const ACCENT: u32 = 0xFF2E5E4E;
    /// Warm paper primary background (`#F5F4F0`, `R >= G >= B`).
    pub const SURFACE_0: u32 = 0xFFF5F4F0;
    /// Elevated warm paper card surface (`#FAF9F6`, `R >= G >= B`).
    pub const SURFACE_1: u32 = 0xFFFAF9F6;
    /// Subtle warm card hover state (`#F0EDE6`, `R >= G >= B`).
    pub const BG_CARD_HOVER: u32 = 0xFFF0EDE6;
    /// Sidebar and secondary panel surface (`#EFECE6`, `R >= G >= B`).
    pub const BG_PANEL: u32 = 0xFFEFECE6;
    /// Subtle badge and grouping surface (`#E8E4DC`, `R >= G >= B`).
    pub const BG_SUBTLE: u32 = 0xFFE8E4DC;
    /// Muted divider and track surface (`#E0DBD1`, `R >= G >= B`).
    pub const BG_MUTED: u32 = 0xFFE0DBD1;
    /// Soft hairline border (`#E2DDD3`, `R >= G >= B`).
    pub const BORDER_SOFT: u32 = 0xFFE2DDD3;
    /// Standard card border (`#D5CFC3`, `R >= G >= B`).
    pub const BORDER: u32 = 0xFFD5CFC3;
    /// Strong interactive border (`#C2BBAE`, `R >= G >= B`).
    pub const BORDER_STRONG: u32 = 0xFFC2BBAE;
    /// Selected card border in warm neutral stone (`#8C867B`, `R >= G >= B`).
    pub const BORDER_SELECTED: u32 = 0xFF8C867B;
    /// Primary ink text (`#1F1E1C`, `R >= G >= B`).
    pub const TEXT_PRIMARY: u32 = 0xFF1F1E1C;
    /// Secondary body text (`#4A4843`, `R >= G >= B`).
    pub const TEXT_SECONDARY: u32 = 0xFF4A4843;
    /// Muted metadata text (`#5E5B55`, `R >= G >= B`, contrast `>= 4.5:1` on `SURFACE_0`).
    pub const TEXT_MUTED: u32 = 0xFF5E5B55;
    /// Pure white foreground for primary accent buttons (`#FFFFFF`).
    pub const ON_ACCENT: u32 = 0xFFFFFFFF;
    /// Inline cards stay flat with zero default drop shadow.
    pub const CARD_SHADOW: &[u32] = &[];

    /// Converts a `0xAARRGGBB` token into a `0xRRGGBB` hex integer for `gpui::rgb()`.
    #[must_use]
    pub const fn rgb24(argb: u32) -> u32 {
        argb & 0x00FF_FFFF
    }
}

/// Strictly bounded four-tier typography scale (`12 / 14 / 16 / 22` px).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AppFontSizes;

impl AppFontSizes {
    /// Caption, metadata, and timestamp size (`12.0` px).
    pub const XS: f32 = 12.0;
    /// Standard body, button, and list item size (`14.0` px).
    pub const SM: f32 = 14.0;
    /// Section title and card heading size (`16.0` px).
    pub const MD: f32 = 16.0;
    /// Primary page header size (`22.0` px).
    pub const LG: f32 = 22.0;
}

/// Concentric corner radius tokens (`inner = max(outer - padding, 4.0)`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AppRadii;

impl AppRadii {
    /// Outer panel radius (`16.0` px).
    pub const OUTER: f32 = 16.0;
    /// Standard flat card radius (`12.0` px).
    pub const CARD: f32 = 12.0;
    /// Inner control radius (`8.0` px).
    pub const CONTROL: f32 = 8.0;

    /// Computes a concentric inner radius from `outer` and container `padding`.
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

    fn srgb_luminance(argb: u32) -> f64 {
        fn chan(c: u8) -> f64 {
            let s = f64::from(c) / 255.0;
            if s <= 0.03928 {
                s / 12.92
            } else {
                ((s + 0.055) / 1.055).powf(2.4)
            }
        }
        let r = ((argb >> 16) & 0xFF) as u8;
        let g = ((argb >> 8) & 0xFF) as u8;
        let b = (argb & 0xFF) as u8;
        0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)
    }

    fn contrast(a: u32, b: u32) -> f64 {
        let l1 = srgb_luminance(a);
        let l2 = srgb_luminance(b);
        let (hi, lo) = if l1 >= l2 { (l1, l2) } else { (l2, l1) };
        (hi + 0.05) / (lo + 0.05)
    }

    #[test]
    fn bamboo_green_and_warm_gray_tokens_satisfy_ui_principles() {
        assert_eq!(AppColors::rgb24(AppColors::ACCENT), 0x2E5E4E);
        assert!(contrast(AppColors::ACCENT, AppColors::ON_ACCENT) >= 7.0);
        assert!(contrast(AppColors::SURFACE_0, AppColors::TEXT_MUTED) >= 4.5);
        assert!(AppColors::CARD_SHADOW.is_empty());

        for token in [
            AppColors::SURFACE_0,
            AppColors::SURFACE_1,
            AppColors::BG_CARD_HOVER,
            AppColors::BG_PANEL,
            AppColors::BG_SUBTLE,
            AppColors::BG_MUTED,
            AppColors::BORDER_SOFT,
            AppColors::BORDER,
            AppColors::BORDER_STRONG,
            AppColors::BORDER_SELECTED,
            AppColors::TEXT_PRIMARY,
            AppColors::TEXT_SECONDARY,
            AppColors::TEXT_MUTED,
        ] {
            let r = (token >> 16) & 0xFF;
            let g = (token >> 8) & 0xFF;
            let b = token & 0xFF;
            assert!(r >= g && g >= b && (r - b) <= 25);
        }

        assert_eq!(
            [
                AppFontSizes::XS,
                AppFontSizes::SM,
                AppFontSizes::MD,
                AppFontSizes::LG
            ],
            [12.0, 14.0, 16.0, 22.0]
        );
        assert_eq!(AppRadii::concentric(16.0, 4.0), 12.0);
        assert_eq!(AppRadii::concentric(8.0, 6.0), 4.0);
    }
}
