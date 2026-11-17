use super::*;
use crate::domain::SegmentId;
use std::time::Instant;

    #[test]
    fn bm25_400k_corpus_latency_under_5ms_and_ask_session() {
        let filler_templates = [
            "上午产品周会讨论了客户端界面布局与深色模式细节。",
            "下午和供应链核对了包装盒打样进度以及发货排期。",
            "傍晚散步记录了周末家庭聚餐菜单和超市采购备忘。",
            "周三技术评审分析了蓝牙重连间隔与固件校验流程。",
        ];
        let mut docs: Vec<String> = Vec::with_capacity(16_000);
        let mut total_chars = 0usize;
        let mut idx = 0usize;
        while total_chars < 400_000 || docs.len() < 16_000 {
            let base = filler_templates[idx % filler_templates.len()];
            let sentence = format!("{idx}:{base}");
            total_chars += sentence.chars().count();
            docs.push(sentence);
            idx += 1;
        }
        docs[3_210] = "张工在架构会上确认：心力豆离线检索必须在五毫秒内完成四十几万字的倒排查询，并采用中文双字切分。".to_string();
        docs[9_876] =
            "李姐承诺下周五之前把第三季度海外渠道的财务对账单和税务发票寄给财务部。".to_string();
        docs[14_200] =
            "我们在调试 rust bindings 和 opus encodings 的时候发现流式解码延迟很低。".to_string();

        let doc_refs: Vec<&str> = docs.iter().map(String::as_str).collect();
        let index = ContextSearchIndex::build(&doc_refs);
        assert!(index.total_chars() >= 400_000);

        let queries = [
            "心力豆离线检索的中文双字切分是谁确认的？",
            "第三季度海外渠道的财务对账单什么时候寄？",
            "rust binding and opus encoding latency",
            "蓝牙连接重连与固件升级",
            "什么怎么我们你们他们",
        ];

        for q in queries {
            let t0 = Instant::now();
            let hits = index.search(q, 30, ScoringMode::default());
            let bm25_elapsed = t0.elapsed();

            let t1 = Instant::now();
            let ranked = rank_texts(q, &doc_refs, 30);
            let idf_elapsed = t1.elapsed();

            println!(
                "[Bench 400k chars ({} docs, {} chars)] query={q:?} -> BM25: {:?} (hits={}), rank_texts: {:?} (hits={})",
                index.doc_count(),
                index.total_chars(),
                bm25_elapsed,
                hits.len(),
                idf_elapsed,
                ranked.len()
            );

            assert!(
                bm25_elapsed.as_millis() < 5,
                "BM25 query exceeded 5ms: {bm25_elapsed:?}"
            );
            assert!(
                idf_elapsed.as_millis() < 5,
                "rank_texts query exceeded 5ms: {idf_elapsed:?}"
            );
        }

        let hits_q1 = index.search(queries[0], 5, ScoringMode::default());
        assert_eq!(hits_q1[0].doc_index, 3_210);
        let ranked_q1 = rank_texts(queries[0], &doc_refs, 5);
        assert_eq!(ranked_q1[0], 3_210);

        let hits_q2 = index.search(queries[1], 5, ScoringMode::default());
        assert_eq!(hits_q2[0].doc_index, 9_876);

        let hits_q3 = index.search(queries[2], 5, ScoringMode::default());
        assert_eq!(hits_q3[0].doc_index, 14_200);

        assert!(!is_delegation_request(
            "他说「帮我发邮件给客户」这句话是在哪段录音？"
        ));
        assert!(is_delegation_request("帮我发邮件给李总确认合同"));

        let mut session = AskSession::new("ask-1", 1_000);
        let corpus = vec![SourceLine {
            label: "S1".to_string(),
            title: "架构会".to_string(),
            text: docs[3_210].clone(),
            source: SourcePointer {
                recording_key: "file:1".to_string(),
                path: None,
                start_ms: 0,
                end_ms: Some(5_000),
                segment_id: SegmentId::new(1).unwrap(),
            },
            at_epoch_sec: Some(1_000),
        }];
        let scope = AskScope {
            with_text: 1,
            without_text: 1,
            processing: 1,
        };

        let notice_out =
            session.submit_question("把这个任务交给代理处理", false, 1_010, &corpus, scope);
        assert_eq!(notice_out, AskStepOutcome::NoticeReplyEmitted);
        assert!(session.messages.last().unwrap().notice);

        let ungrounded = session.submit_question(
            "量子计算机的制冷剂配方是什么？",
            false,
            1_020,
            &corpus,
            scope,
        );
        assert_eq!(ungrounded, AskStepOutcome::UngroundedShortCircuit);
        assert!(!session.messages.last().unwrap().grounded);

        let dispatch =
            session.submit_question("心力豆离线检索是谁确认的？", false, 1_030, &corpus, scope);
        assert!(matches!(dispatch, AskStepOutcome::DispatchLlm(_)));
        assert!(session.in_flight);

        let done = session.complete_answer("张工确认了心力豆离线检索方案 [S1]。".to_string());
        assert_eq!(done, AskStepOutcome::AnswerCompleted { cited_count: 1 });
        assert!(!session.in_flight);
    }
