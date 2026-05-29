declare module "*.css";

interface ImportMetaEnv {
  readonly VITE_WISPTERM_WEB_BUILD_TIME?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
