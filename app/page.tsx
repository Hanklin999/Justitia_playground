import Link from "next/link";

export default function HomePage() {
  return (
    <section className="hero container">
      <div className="eyebrow">ROC 105–114</div>
      <h1>Justitia&apos;s playground</h1>
      <p className="lead">司律陪考資料庫</p>
      <div className="actions">
        <Link className="button primary" href="/practice">開始刷題</Link>
        <Link className="button secondary" href="/history">查看作答紀錄</Link>
      </div>
      <div className="feature-grid">
        <article><strong>年度正式卷</strong><span>依年份選擇四份綜合法學試卷，保留官方題序與時長。</span></article>
        <article><strong>科目自組卷</strong><span>複選年度與科目，自訂名稱、模考日期與題數；自訂題數會優先抽取近 10 回同範圍錯題。</span></article>
        <article><strong>錯題與筆記</strong><span>分開保存模考與檢討星號／筆記，並從指定作答回合建立不計時複習組卷。</span></article>
      </div>
    </section>
  );
}
