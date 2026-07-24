import type { Metadata } from "next";
import Link from "next/link";
import AuthStatus from "@/components/auth-status";
import "./globals.css";

export const metadata: Metadata = {
  title: "Justitia's playground",
  description: "司律陪考資料庫",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="zh-Hant">
      <body>
        <header className="site-header">
          <Link className="brand" href="/">Justitia's playground</Link>
          <nav>
            <Link href="/practice">開始練習</Link>
            <Link href="/history">歷史紀錄</Link>
            <Link href="/review">今日複習</Link>
            <AuthStatus />
          </nav>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
