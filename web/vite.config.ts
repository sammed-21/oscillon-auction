import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The app imports ../deployments/*.json and ../replay/results.csv straight from the repo.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, fs: { allow: [".."] } },
});
