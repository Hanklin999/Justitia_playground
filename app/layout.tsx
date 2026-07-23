import type { Metadata } from "next";
import Link from "next/link";
import AuthStatus from "@/components/auth-status";
import "./globals.css";

export const metadata: Metadata = {
  title: "朱斯提亞練功房",
  description: "簡單快速，找到題目",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="zh-Hant">
      <body>
        <header className="site-header">
          <Link className="brand" href="/">朱斯提亞練功房</Link>
          <nav>
            <Link href="/practice">開始練習</Link>
            <Link href="/history">歷史紀錄</Link>
            <AuthStatus />
          </nav>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
