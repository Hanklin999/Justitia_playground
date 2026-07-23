import Link from "next/link";

export default function HomePage() {
  return (
    <section className="hero container">
      <div className="eyebrow">Justitia_playground</div>
      <h1>朱斯提亞練功房</h1>
      <p className="lead">簡單快速，找到題目。用正式試卷時長，完成一次真正可追蹤的司律一試模擬。</p>
      <div className="actions">
        <Link className="button primary" href="/practice">選擇試卷</Link>
        <Link className="button secondary" href="/login">Email 登入</Link>
      </div>
      <div className="feature-grid">
        <article><strong>正式時長</strong><span>每次作答保留當次試卷的官方考試時間。</span></article>
        <article><strong>到時交卷</strong><span>截止後鎖定答案，並以 timeout 留下考試 Log。</span></article>
        <article><strong>立即看分數</strong><span>單卷完成後查看答對、答錯與未作答，不提供詳解。</span></article>
      </div>
    </section>
  );
}
