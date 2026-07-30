import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  metadataBase: new URL("https://nexvoice-ai.movielin8866.workers.dev/"),
  title: "NexVoice — 本地優先 Apple Silicon 語音聽寫 macOS App",
  description: "極速熱鍵錄音、預設 100% 本機零費用 Whisper 轉錄，支援 Gateway (Gemini 雲端 STT、Groq/NIM/Gemini 文本潤飾) 與 App 雲端整合，提供 21 款炫彩 HUD 動態介面與 7 種外框。",
  openGraph: {
    title: "NexVoice — 本地優先 Apple Silicon 語音聽寫 macOS App",
    description: "極速熱鍵錄音、預設 100% 本機零費用 Whisper 轉錄，支援 Gateway (Gemini 雲端 STT、Groq/NIM/Gemini 文本潤飾) 與 App 雲端整合，提供 21 款炫彩 HUD 動態介面與 7 種外框。",
    images: [
      {
        url: "/og-v2.png",
        width: 1200,
        height: 630,
        alt: "NexVoice 展示 21 款真實 Swift HUD 動態視覺介面與獨家外框設計",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "NexVoice — 本地優先 Apple Silicon 語音聽寫 macOS App",
    description: "極速熱鍵錄音、預設 100% 本機零費用 Whisper 轉錄，支援 Gateway (Gemini 雲端 STT、Groq/NIM/Gemini 文本潤飾) 與 App 雲端整合，提供 21 款炫彩 HUD 動態介面與 7 種外框。",
    images: [
      {
        url: "/og-v2.png",
        alt: "NexVoice 展示 21 款真實 Swift HUD 動態視覺介面與獨家外框設計",
      },
    ],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-TW" className="dark scroll-smooth">
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased bg-[#07090e] text-[#ededed] min-h-screen selection:bg-cyan-500/30 selection:text-cyan-200`}
      >
        {children}
      </body>
    </html>
  );
}
