import Link from "next/link";

export default function HomePage() {
  return (
    <section className="hero container">
      <div className="eyebrow">105-114 司律一試備考工具</div>
      <h1>Justitia&apos;s playground</h1>
      <p className="lead">司律陪考資料庫 | 攻克國考有如神助</p>
      <p className="release-meta">v.3.12.1，last updated 2026/07/25 12:34:33 (UTC+8)</p>
      <div className="actions">
        <Link className="button primary" href="/practice">開始刷題</Link>
        <Link className="button secondary" href="/history">查看作答紀錄</Link>
        <Link className="button secondary" href="/review">今日待複習</Link>
      </div>
      <div className="feature-grid">
        <article><strong>年度正式卷</strong><span>依年份選擇四份綜合法學試卷，保留官方題序與時長。</span></article>
        <article><strong>科目自組卷</strong><span>複選年度與科目，自訂名稱、模考日期與題數；自訂題數會優先抽取近 10 回同範圍錯題。</span></article>
        <article><strong>錯題與筆記</strong><span>分開保存模考與檢討星號／筆記，並從指定作答回合建立不計時複習組卷。</span></article>
        <article><strong>節奏與間隔複習</strong><span>追蹤每題有效時間、改答案與信心程度，安排 1／3／7／14／30 天後再次練習。</span></article>
      </div>
    </section>
  );
}
