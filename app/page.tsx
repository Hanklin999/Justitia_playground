import Link from "next/link";

export default function HomePage() {
  return (
    <section className="hero container">
      <div className="eyebrow">ROC 110–114</div>
      <h1>Justitia&apos;s playground</h1>
      <p className="lead">司律陪考資料庫</p>
      <div className="actions">
        <Link className="button primary" href="/practice">開始刷題</Link>
        <Link className="button secondary" href="/history">查看作答紀錄</Link>
      </div>
      <div className="feature-grid">
        <article><strong>年度正式卷</strong><span>依年份選擇四份綜合法學試卷，保留官方題序與時長。</span></article>
        <article><strong>科目自組卷</strong><span>複選年度與科目，從近五年題池抽出對應題數並比例計時。</span></article>
        <article><strong>錯題與筆記</strong><span>星號標記不會的題目、留下筆記，並建立不計時錯題重刷。</span></article>
      </div>
    </section>
  );
}
