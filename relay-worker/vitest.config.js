import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        // 所有测试共用一个数据库，各自用不同的设备和消息编号。
        isolatedStorage: false,
        singleWorker: true,
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: { bindings: { ADMIN_PASSWORD: "test-admin-password" } },
      },
    },
  },
});
