use super::*;
use crate::domain::SegmentId;

#[test]
fn bm25_400k_corpus_ranking_and_ask_session() {
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
    assert_eq!(index.doc_count(), docs.len());

    let queries = [
        "心力豆离线检索的中文双字切分是谁确认的？",
        "第三季度海外渠道的财务对账单什么时候寄？",
        "rust binding and opus encoding latency",
        "蓝牙连接重连与固件升级",
        "什么怎么我们你们他们",
    ];

    for q in queries {
        let idf_indices: Vec<usize> = index
            .search(q, 30, ScoringMode::IdfSum)
            .into_iter()
            .map(|h| h.doc_index)
            .collect();
        let ranked = rank_texts(q, &doc_refs, 30);
        assert_eq!(ranked, idf_indices, "rank_texts must match ContextSearchIndex IdfSum for {q:?}");
    }

    assert!(index.search(queries[4], 10, ScoringMode::default()).is_empty());
    assert!(rank_texts(queries[4], &doc_refs, 10).is_empty());

    let hits_q1 = index.search(queries[0], 5, ScoringMode::default());
    assert_eq!(hits_q1[0].doc_index, 3_210);
    assert!(hits_q1[0].score > 0.0);
    let ranked_q1 = rank_texts(queries[0], &doc_refs, 5);
    assert_eq!(ranked_q1[0], 3_210);

    let hits_q2 = index.search(queries[1], 5, ScoringMode::default());
    assert_eq!(hits_q2[0].doc_index, 9_876);
    assert_eq!(rank_texts(queries[1], &doc_refs, 5)[0], 9_876);

    let hits_q3 = index.search(queries[2], 5, ScoringMode::default());
    assert_eq!(hits_q3[0].doc_index, 14_200);
    assert_eq!(rank_texts(queries[2], &doc_refs, 5)[0], 14_200);

    assert!(!index.search(queries[3], 5, ScoringMode::default()).is_empty());

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

#[test]
fn bm25_tf_length_normalization_stemming_and_tie_breaking() {
    let docs = [
        "opus streaming decoder latency tuning with long extra filler words padding document length",
        "opus opus opus streaming",
        "opus streaming",
        "unrelated hardware battery note",
    ];
    let mut index = ContextSearchIndex::build(&docs);

    let bm25_hits = index.search("opus", 10, ScoringMode::default());
    assert_eq!(
        bm25_hits.iter().map(|h| h.doc_index).collect::<Vec<_>>(),
        vec![1, 2, 0]
    );
    assert!(bm25_hits[0].score > bm25_hits[1].score);
    assert!(bm25_hits[1].score > bm25_hits[2].score);

    let idf_hits = index.search("opus", 10, ScoringMode::IdfSum);
    assert_eq!(
        idf_hits.iter().map(|h| h.doc_index).collect::<Vec<_>>(),
        vec![0, 1, 2]
    );
    assert_eq!(rank_texts("opus", &docs, 10), vec![0, 1, 2]);
    assert_eq!(rank_texts("opus", &docs, 2), vec![0, 1]);
    assert!(rank_texts("opus", &docs, 0).is_empty());
    assert!(rank_texts("opus", &[], 5).is_empty());

    let stemmed = index.query_indices("streams tuned", 5);
    assert_eq!(index.last_hit_count(), stemmed.len());
    assert!(stemmed.contains(&0));
    assert!(stemmed.contains(&1));
    assert!(stemmed.contains(&2));

    for empty_q in ["", "   ", "！？...", "a", "什么怎么我们你们他们"] {
        assert!(rank_texts(empty_q, &docs, 10).is_empty());
        assert!(index.search(empty_q, 10, ScoringMode::IdfSum).is_empty());
    }

    let case_docs = [
        "RUST binding only",
        "Rust BINDINGS repeated bindings bindings",
        "no match here",
    ];
    let case_index = ContextSearchIndex::build(&case_docs);
    for q in ["rust bindings", "RUST BINDING", "Bindings"] {
        let expected: Vec<usize> = case_index
            .search(q, 10, ScoringMode::IdfSum)
            .into_iter()
            .map(|h| h.doc_index)
            .collect();
        assert_eq!(rank_texts(q, &case_docs, 10), expected, "parity mismatch for {q:?}");
    }
    assert_eq!(rank_texts("bindings", &case_docs, 10), vec![1, 0]);
}
