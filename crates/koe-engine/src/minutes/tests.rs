use super::*;
use crate::domain::*;


    fn minutes_with_claim(
        claim: &str,
        citations: Vec<SegmentId>,
        spine_revision: u64,
    ) -> MeetingMinutes {
        MeetingMinutes {
            version: 2,
            spine_revision,
            title: "核算".to_string(),
            overview: "核对结果".to_string(),
            topics: vec![MinuteTopic {
                title: "薪资".to_string(),
                summary: "讨论情况".to_string(),
                citations: citations.clone(),
                points: vec![MinutePoint {
                    claim: claim.to_string(),
                    speaker: None,
                    owner: None,
                    due: None,
                    citations,
                }],
                fishbone: None,
            }],
            decisions: Vec::new(),
            actions: Vec::new(),
            questions: Vec::new(),
            fishbones: Vec::new(),
            terms: Vec::new(),
            custom_sections: Vec::new(),
            review_items: Vec::new(),
        }
    }

    #[test]
    fn rejects_cross_segment_wage_and_percentage_stitching_but_accepts_single_segment() {
        let mut spine = UtteranceSpine::new("rec-wage");
        let s1 = spine
            .append_segment("合同约定基本工资为3910元。", 0, 1_500, "zh", "qwen")
            .unwrap();
        let s2 = spine
            .append_segment("本月出勤率是80%。", 1_500, 3_000, "zh", "qwen")
            .unwrap();
        let s3 = spine
            .append_segment(
                "所以实发工资按3910元乘以80%折算。",
                3_000,
                4_500,
                "zh",
                "qwen",
            )
            .unwrap();

        let stitched = validate_minutes_grounding(
            &minutes_with_claim(
                "员工实发工资按3910元乘以80%计算",
                vec![s1, s2],
                spine.revision(),
            ),
            &spine,
        );
        assert_eq!(
            stitched,
            Err(MinutesValidationError::UngroundedWageCalculation {
                claim: "员工实发工资按3910元乘以80%计算".to_string(),
            })
        );

        let baseless_ratio = validate_minutes_grounding(
            &minutes_with_claim("社保缴费基数按80%计算", vec![s1, s2], spine.revision()),
            &spine,
        );
        assert_eq!(
            baseless_ratio,
            Err(MinutesValidationError::BaselessRatioCalculation {
                claim: "社保缴费基数按80%计算".to_string(),
            })
        );

        let uncited_pct = validate_minutes_grounding(
            &minutes_with_claim("本月出勤率达到85%", vec![s2], spine.revision()),
            &spine,
        );
        assert_eq!(
            uncited_pct,
            Err(MinutesValidationError::UncitedPercentageNumber {
                claim: "本月出勤率达到85%".to_string(),
                percentage: "85%".to_string(),
            })
        );

        let grounded = validate_minutes_grounding(
            &minutes_with_claim(
                "员工实发工资按3910元乘以80%计算",
                vec![s3],
                spine.revision(),
            ),
            &spine,
        );
        assert_eq!(grounded, Ok(()));
    }

    #[test]
    fn longest_match_single_pass_term_replacement_and_heard_pruning() {
        let mut spine = UtteranceSpine::new("rec-terms");
        spine.append_segment("今天测试深科和深科Work录音豆。", 0, 1000, "zh", "qwen");
        let raw = r#"{
            "schemaVersion": 2,
            "title": "深科的深科Work录音豆",
            "overview": "测试深科设备",
            "topics": [{"text": "深科蓝牙", "sources": ["S1"]}],
            "decisions": [],
            "actions": [],
            "questions": [],
            "terms": [{"name": "声刻", "note": "品牌", "heard": ["深科"], "sources": ["S1"]}]
        }"#;
        let mut doc = parse_meeting_minutes_json(raw, &spine).unwrap();
        doc.replace_terms(&[("深科", "声刻"), ("深科Work", "Soundcore Work")]);
        assert_eq!(doc.title, "声刻的Soundcore Work录音豆");
        assert!(doc.terms[0].heard.is_empty());
    }

    #[test]
    fn build_meeting_minutes_prompt_includes_custom_instructions_without_custom_sections() {
        for (locale, instruction) in [
            ("zh", "只写有来源的结论、行动和记忆。"),
            ("en", "Keep only cited outcomes."),
            ("ja", "出典のある結論のみ記載してください。"),
        ] {
            let prompt = build_meeting_minutes_prompt(
                "[S1] Example",
                locale,
                &[],
                Some(&format!("  {instruction}  ")),
                &[],
            );
            assert!(
                prompt.contains(&format!("\n- {instruction}")),
                "locale {locale} prompt missing custom instruction: {prompt}"
            );
            assert!(!prompt.contains("\"custom\":"));
        }

        let with_sections = build_meeting_minutes_prompt(
            "[S1] Example",
            "zh",
            &["风险与建议".to_string()],
            Some("仅输出高置信结论。"),
            &[],
        );
        assert!(with_sections.contains("\"custom\":"));
        assert!(with_sections.contains("\n- 仅输出高置信结论。"));
    }
