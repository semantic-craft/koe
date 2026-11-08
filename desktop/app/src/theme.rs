use koe_desktop_core::EditorialCardRole;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppColors;

impl AppColors {
    pub const CANVAS: u32 = 0xFFFAFAFA;
    pub const SIDEBAR: u32 = 0xFFF0F0F2;
    pub const SURFACE_0: u32 = 0xFFFAFAFA;
    pub const BG_PANEL: u32 = 0xFFF0F0F2;
    pub const SURFACE_1: u32 = 0xFFF0F0F2;
    pub const BG_CARD: u32 = 0xFFFFFFFF;
    pub const BG_SUBTLE: u32 = 0xFFE6E6E9;
    pub const BG_CARD_HOVER: u32 = 0xFFDADADD;
    pub const BG_MUTED: u32 = 0xFFD1D1D5;
    pub const BORDER: u32 = 0xFFCCCCD2;
    pub const BORDER_SOFT: u32 = 0xFFE2E2E7;
    pub const BORDER_STRONG: u32 = 0xFFB8B8C0;
    pub const BORDER_SELECTED: u32 = 0xFFD9480F;
    pub const TEXT_PRIMARY: u32 = 0xFF171719;
    pub const TEXT_SECONDARY: u32 = 0xFF515157;
    pub const TEXT_MUTED: u32 = 0xFF626269;
    pub const ACCENT: u32 = 0xFFD9480F;
    pub const ACCENT_HOVER: u32 = 0xFFB83B0B;
    pub const ACCENT_SOFT: u32 = 0xFFFFF1E6;
    pub const ACCENT_BORDER: u32 = 0xFFFDBA8C;
    pub const ORANGE_BRAND: u32 = 0xFFFF5F05;
    pub const ORANGE_ACTION: u32 = 0xFFD9480F;
    pub const ORANGE_DEEP: u32 = 0xFF9A3412;
    pub const ORANGE_TINT: u32 = 0xFFFFF1E6;
    pub const ORANGE_BORDER: u32 = 0xFFFDBA8C;
    pub const WAVE_UNPLAYED: u32 = 0xFF9E9EA6;
    pub const ON_ACCENT: u32 = 0xFFFFFFFF;
    pub const SUCCESS: u32 = 0xFF18713B;
    pub const SUCCESS_SOFT: u32 = 0xFFE8F5ED;
    pub const WARNING: u32 = 0xFF9A5B13;
    pub const WARNING_SOFT: u32 = 0xFFFEF4E6;
    pub const DANGER: u32 = 0xFFB42318;
    pub const DANGER_SOFT: u32 = 0xFFFEECEB;
    pub const INFO: u32 = 0xFF1B618A;
    pub const INFO_SOFT: u32 = 0xFFECF6FA;
    pub const CARD_SHADOW: &[u32] = &[];

    #[must_use]
    pub const fn rgb24(argb: u32) -> u32 {
        argb & 0x00FF_FFFF
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EditorialRolePalette {
    pub bg: u32,
    pub border: u32,
    pub badge_text: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AIVisualEditorialPalette;

impl AIVisualEditorialPalette {
    pub const CONCLUSION_AMBER_BG: u32 = 0xFFFCEEE5;
    pub const CONCLUSION_AMBER_BORDER: u32 = 0xFFFF5F05;
    pub const CONCLUSION_AMBER_BADGE: u32 = 0xFF9A3412;

    pub const ACTIONS_SAGE_BG: u32 = 0xFFDFEFCD;
    pub const ACTIONS_SAGE_BORDER: u32 = 0xFFB8DE98;
    pub const ACTIONS_SAGE_BADGE: u32 = 0xFF18713B;

    pub const RISKS_ROSE_BG: u32 = 0xFFFAECEF;
    pub const RISKS_ROSE_BORDER: u32 = 0xFFF5BDC7;
    pub const RISKS_ROSE_BADGE: u32 = 0xFFA72727;

    pub const FLOW_CREAM_BG: u32 = 0xFFFAF7EB;
    pub const FLOW_CREAM_BORDER: u32 = 0xFFE8DEB0;
    pub const FLOW_CREAM_BADGE: u32 = 0xFF6B5812;

    pub const QUESTIONS_SKY_BG: u32 = 0xFFECF6FA;
    pub const QUESTIONS_SKY_BORDER: u32 = 0xFFBFDFEF;
    pub const QUESTIONS_SKY_BADGE: u32 = 0xFF1B618A;

    pub const TAKEAWAYS_LAVENDER_BG: u32 = 0xFFECEFFA;
    pub const TAKEAWAYS_LAVENDER_BORDER: u32 = 0xFFC0CAF2;
    pub const TAKEAWAYS_LAVENDER_BADGE: u32 = 0xFF2A429E;

    #[must_use]
    pub const fn for_role(role: EditorialCardRole) -> EditorialRolePalette {
        match role {
            EditorialCardRole::ConclusionAmber => EditorialRolePalette {
                bg: Self::CONCLUSION_AMBER_BG,
                border: Self::CONCLUSION_AMBER_BORDER,
                badge_text: Self::CONCLUSION_AMBER_BADGE,
            },
            EditorialCardRole::ActionsBlue => EditorialRolePalette {
                bg: Self::ACTIONS_SAGE_BG,
                border: Self::ACTIONS_SAGE_BORDER,
                badge_text: Self::ACTIONS_SAGE_BADGE,
            },
            EditorialCardRole::RisksCoral => EditorialRolePalette {
                bg: Self::RISKS_ROSE_BG,
                border: Self::RISKS_ROSE_BORDER,
                badge_text: Self::RISKS_ROSE_BADGE,
            },
            EditorialCardRole::FlowEmerald => EditorialRolePalette {
                bg: Self::FLOW_CREAM_BG,
                border: Self::FLOW_CREAM_BORDER,
                badge_text: Self::FLOW_CREAM_BADGE,
            },
            EditorialCardRole::QuestionsSlate => EditorialRolePalette {
                bg: Self::QUESTIONS_SKY_BG,
                border: Self::QUESTIONS_SKY_BORDER,
                badge_text: Self::QUESTIONS_SKY_BADGE,
            },
            EditorialCardRole::TakeawaysPlum => EditorialRolePalette {
                bg: Self::TAKEAWAYS_LAVENDER_BG,
                border: Self::TAKEAWAYS_LAVENDER_BORDER,
                badge_text: Self::TAKEAWAYS_LAVENDER_BADGE,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AppFontSizes;

impl AppFontSizes {
    pub const XS: f32 = 12.0;
    pub const SM: f32 = 14.0;
    pub const MD: f32 = 16.0;
    pub const LG: f32 = 22.0;
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AppRadii;

impl AppRadii {
    pub const OUTER: f32 = 16.0;
    pub const CARD: f32 = 12.0;
    pub const CONTROL: f32 = 8.0;

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
    fn vecta_illinois_orange_and_editorial_tokens_satisfy_ui_principles() {
        assert_eq!(AppColors::rgb24(AppColors::ACCENT), 0xD9480F);
        assert_eq!(AppColors::rgb24(AppColors::ORANGE_BRAND), 0xFF5F05);
        assert!(contrast(AppColors::ACCENT, AppColors::ON_ACCENT) >= 4.25);
        assert!(contrast(AppColors::ORANGE_DEEP, AppColors::ON_ACCENT) >= 7.0);
        assert!(contrast(AppColors::SURFACE_0, AppColors::TEXT_MUTED) >= 4.5);
        assert!(contrast(AppColors::SURFACE_1, AppColors::TEXT_MUTED) >= 4.5);
        assert!(AppColors::CARD_SHADOW.is_empty());

        for token in [
            AppColors::SURFACE_0,
            AppColors::BG_PANEL,
            AppColors::SURFACE_1,
            AppColors::BG_SUBTLE,
            AppColors::BG_CARD_HOVER,
            AppColors::BG_MUTED,
            AppColors::BORDER,
            AppColors::BORDER_SOFT,
            AppColors::TEXT_PRIMARY,
            AppColors::TEXT_SECONDARY,
            AppColors::TEXT_MUTED,
        ] {
            let r = ((token >> 16) & 0xFF) as i32;
            let g = ((token >> 8) & 0xFF) as i32;
            let b = (token & 0xFF) as i32;
            assert!((r - b).abs() <= 12 && (r - g).abs() <= 12);
        }

        let roles = [
            (EditorialCardRole::ConclusionAmber, 0xFFFCEEE5),
            (EditorialCardRole::ActionsBlue, 0xFFDFEFCD),
            (EditorialCardRole::RisksCoral, 0xFFFAECEF),
            (EditorialCardRole::FlowEmerald, 0xFFFAF7EB),
            (EditorialCardRole::QuestionsSlate, 0xFFECF6FA),
            (EditorialCardRole::TakeawaysPlum, 0xFFECEFFA),
        ];
        for (role, expected_bg) in roles {
            let pal = AIVisualEditorialPalette::for_role(role);
            assert_eq!(pal.bg, expected_bg);
            assert!(contrast(pal.bg, AppColors::TEXT_PRIMARY) >= 7.0);
            assert!(contrast(pal.bg, pal.badge_text) >= 4.5);
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
