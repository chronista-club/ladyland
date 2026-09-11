#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import * as db from "./db.js";

// MCPサーバー作成
const server = new Server(
  {
    name: "bikeboy-mcp",
    version: "0.1.0",
  },
  {
    capabilities: {
      tools: {},
    },
  },
);

// ツール一覧
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      // Context管理
      {
        name: "create_context",
        description: "新しいContextを作成する",
        inputSchema: {
          type: "object" as const,
          properties: {
            name: {
              type: "string",
              description: "Context名（例: bikeboy, vantage）",
            },
            defaultScene: {
              type: "string",
              description: "デフォルトのScene名",
            },
          },
          required: ["name"],
        },
      },
      {
        name: "list_contexts",
        description: "全てのContextを一覧表示する",
        inputSchema: {
          type: "object" as const,
          properties: {},
        },
      },
      {
        name: "delete_context",
        description: "Contextを削除する",
        inputSchema: {
          type: "object" as const,
          properties: {
            name: { type: "string", description: "削除するContext名" },
          },
          required: ["name"],
        },
      },

      // Scene管理
      {
        name: "create_scene",
        description: "Context内に新しいSceneを作成する",
        inputSchema: {
          type: "object" as const,
          properties: {
            contextName: { type: "string", description: "親Context名" },
            name: {
              type: "string",
              description: "Scene名（例: coding, debug）",
            },
            ledR: { type: "number", description: "LED色 R (0-127)" },
            ledG: { type: "number", description: "LED色 G (0-127)" },
            ledB: { type: "number", description: "LED色 B (0-127)" },
          },
          required: ["contextName", "name"],
        },
      },
      {
        name: "list_scenes",
        description: "Context内のSceneを一覧表示する",
        inputSchema: {
          type: "object" as const,
          properties: {
            contextName: { type: "string", description: "Context名" },
          },
          required: ["contextName"],
        },
      },

      // App管理
      {
        name: "add_app",
        description: "Sceneにアプリを追加する",
        inputSchema: {
          type: "object" as const,
          properties: {
            contextName: { type: "string", description: "Context名" },
            sceneName: { type: "string", description: "Scene名" },
            bundleId: { type: "string", description: "アプリのBundle ID" },
            windowTitle: {
              type: "string",
              description: "ウィンドウタイトルフィルター",
            },
            x: { type: "number", description: "X座標" },
            y: { type: "number", description: "Y座標" },
            width: { type: "number", description: "幅" },
            height: { type: "number", description: "高さ" },
          },
          required: ["contextName", "sceneName", "bundleId"],
        },
      },
      {
        name: "list_apps",
        description: "Scene内のアプリを一覧表示する",
        inputSchema: {
          type: "object" as const,
          properties: {
            contextName: { type: "string", description: "Context名" },
            sceneName: { type: "string", description: "Scene名" },
          },
          required: ["contextName", "sceneName"],
        },
      },
      {
        name: "update_app_position",
        description: "アプリのウィンドウ位置を更新する",
        inputSchema: {
          type: "object" as const,
          properties: {
            contextName: { type: "string", description: "Context名" },
            sceneName: { type: "string", description: "Scene名" },
            bundleId: { type: "string", description: "アプリのBundle ID" },
            x: { type: "number", description: "X座標" },
            y: { type: "number", description: "Y座標" },
            width: { type: "number", description: "幅" },
            height: { type: "number", description: "高さ" },
          },
          required: [
            "contextName",
            "sceneName",
            "bundleId",
            "x",
            "y",
            "width",
            "height",
          ],
        },
      },

      // パッドマッピング
      {
        name: "set_pad_mapping",
        description: "パッドにContext/Sceneを割り当てる",
        inputSchema: {
          type: "object" as const,
          properties: {
            pad: { type: "number", description: "パッド番号 (1-8)" },
            contextName: { type: "string", description: "Context名" },
            sceneName: { type: "string", description: "Scene名（省略可）" },
          },
          required: ["pad", "contextName"],
        },
      },
      {
        name: "list_pad_mappings",
        description: "パッドマッピングを一覧表示する",
        inputSchema: {
          type: "object" as const,
          properties: {},
        },
      },

      // ノブマッピング
      {
        name: "set_knob_mapping",
        description: "ノブに機能を割り当てる",
        inputSchema: {
          type: "object" as const,
          properties: {
            knob: { type: "number", description: "ノブ番号 (1-8)" },
            function: {
              type: "string",
              description: "機能名（例: led-brightness）",
            },
          },
          required: ["knob", "function"],
        },
      },

      // エクスポート
      {
        name: "export_config",
        description: "設定をKDL形式でエクスポートする",
        inputSchema: {
          type: "object" as const,
          properties: {},
        },
      },
      {
        name: "save_config",
        description: "設定をファイルに保存する",
        inputSchema: {
          type: "object" as const,
          properties: {
            path: {
              type: "string",
              description:
                "保存先パス（デフォルト: ~/.config/bikeboy/launcher.kdl）",
            },
          },
        },
      },

      // ユーティリティ
      {
        name: "get_running_apps",
        description: "現在起動中のアプリ一覧を取得する",
        inputSchema: {
          type: "object" as const,
          properties: {},
        },
      },
      {
        name: "capture_current_layout",
        description:
          "現在のウィンドウレイアウトをキャプチャしてSceneとして保存する",
        inputSchema: {
          type: "object" as const,
          properties: {
            contextName: { type: "string", description: "保存先Context名" },
            sceneName: { type: "string", description: "保存するScene名" },
          },
          required: ["contextName", "sceneName"],
        },
      },
    ],
  };
});

// 引数取得ヘルパー
function getArg<T>(
  args: Record<string, unknown> | undefined,
  key: string,
): T | undefined {
  return args?.[key] as T | undefined;
}

function requireArg<T>(
  args: Record<string, unknown> | undefined,
  key: string,
): T {
  const value = args?.[key];
  if (value === undefined) {
    throw new Error(`必須引数 "${key}" がありません`);
  }
  return value as T;
}

// ツール実行
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      // Context管理
      case "create_context": {
        const context = await db.createContext({
          name: requireArg<string>(args, "name"),
          defaultScene: getArg<string>(args, "defaultScene"),
        });
        return {
          content: [
            { type: "text", text: `Context "${context.name}" を作成しました` },
          ],
        };
      }

      case "list_contexts": {
        const contexts = await db.getContexts();
        const text =
          contexts.length > 0
            ? contexts
                .map(
                  (c) =>
                    `- ${c.name}${c.defaultScene ? ` (default: ${c.defaultScene})` : ""}`,
                )
                .join("\n")
            : "Contextがありません";
        return { content: [{ type: "text", text }] };
      }

      case "delete_context": {
        const contextName = requireArg<string>(args, "name");
        const context = await db.getContextByName(contextName);
        if (!context) {
          return {
            content: [
              {
                type: "text",
                text: `Context "${contextName}" が見つかりません`,
              },
            ],
          };
        }
        await db.deleteContext(context.id!);
        return {
          content: [
            { type: "text", text: `Context "${contextName}" を削除しました` },
          ],
        };
      }

      // Scene管理
      case "create_scene": {
        const contextName = requireArg<string>(args, "contextName");
        const context = await db.getContextByName(contextName);
        if (!context) {
          return {
            content: [
              {
                type: "text",
                text: `Context "${contextName}" が見つかりません`,
              },
            ],
          };
        }

        const ledR = getArg<number>(args, "ledR");
        const ledG = getArg<number>(args, "ledG");
        const ledB = getArg<number>(args, "ledB");
        const ledColor =
          ledR !== undefined && ledG !== undefined && ledB !== undefined
            ? { r: ledR, g: ledG, b: ledB }
            : undefined;

        const scene = await db.createScene({
          name: requireArg<string>(args, "name"),
          contextId: context.id!,
          ledColor,
        });

        return {
          content: [
            {
              type: "text",
              text: `Scene "${scene.name}" を ${context.name} に作成しました`,
            },
          ],
        };
      }

      case "list_scenes": {
        const contextName = requireArg<string>(args, "contextName");
        const context = await db.getContextByName(contextName);
        if (!context) {
          return {
            content: [
              {
                type: "text",
                text: `Context "${contextName}" が見つかりません`,
              },
            ],
          };
        }

        const scenes = await db.getScenesByContext(context.id!);
        const text =
          scenes.length > 0
            ? scenes
                .map((s) => {
                  let line = `- ${s.name}`;
                  if (s.ledColor) {
                    line += ` (LED: rgb(${s.ledColor.r}, ${s.ledColor.g}, ${s.ledColor.b}))`;
                  }
                  return line;
                })
                .join("\n")
            : "Sceneがありません";

        return { content: [{ type: "text", text }] };
      }

      // App管理
      case "add_app": {
        const contextName = requireArg<string>(args, "contextName");
        const context = await db.getContextByName(contextName);
        if (!context) {
          return {
            content: [
              {
                type: "text",
                text: `Context "${contextName}" が見つかりません`,
              },
            ],
          };
        }

        const sceneName = requireArg<string>(args, "sceneName");
        const scenes = await db.getScenesByContext(context.id!);
        const scene = scenes.find((s) => s.name === sceneName);
        if (!scene) {
          return {
            content: [
              { type: "text", text: `Scene "${sceneName}" が見つかりません` },
            ],
          };
        }

        const existingApps = await db.getAppsByScene(scene.id!);

        const x = getArg<number>(args, "x");
        const y = getArg<number>(args, "y");
        const width = getArg<number>(args, "width");
        const height = getArg<number>(args, "height");
        const position =
          x !== undefined &&
          y !== undefined &&
          width !== undefined &&
          height !== undefined
            ? { x, y, width, height }
            : undefined;

        const app = await db.createApp({
          sceneId: scene.id!,
          bundleId: requireArg<string>(args, "bundleId"),
          windowTitle: getArg<string>(args, "windowTitle"),
          position,
          orderIndex: existingApps.length,
        });

        return {
          content: [
            { type: "text", text: `アプリ "${app.bundleId}" を追加しました` },
          ],
        };
      }

      case "list_apps": {
        const contextName = requireArg<string>(args, "contextName");
        const context = await db.getContextByName(contextName);
        if (!context) {
          return {
            content: [
              {
                type: "text",
                text: `Context "${contextName}" が見つかりません`,
              },
            ],
          };
        }

        const sceneName = requireArg<string>(args, "sceneName");
        const scenes = await db.getScenesByContext(context.id!);
        const scene = scenes.find((s) => s.name === sceneName);
        if (!scene) {
          return {
            content: [
              { type: "text", text: `Scene "${sceneName}" が見つかりません` },
            ],
          };
        }

        const apps = await db.getAppsByScene(scene.id!);
        const text =
          apps.length > 0
            ? apps
                .map((a) => {
                  let line = `- ${a.bundleId}`;
                  if (a.windowTitle) line += ` (window: "${a.windowTitle}")`;
                  if (a.position)
                    line += ` [${a.position.x}, ${a.position.y}, ${a.position.width}x${a.position.height}]`;
                  return line;
                })
                .join("\n")
            : "アプリがありません";

        return { content: [{ type: "text", text }] };
      }

      case "update_app_position": {
        const contextName = requireArg<string>(args, "contextName");
        const context = await db.getContextByName(contextName);
        if (!context) {
          return {
            content: [
              {
                type: "text",
                text: `Context "${contextName}" が見つかりません`,
              },
            ],
          };
        }

        const sceneName = requireArg<string>(args, "sceneName");
        const scenes = await db.getScenesByContext(context.id!);
        const scene = scenes.find((s) => s.name === sceneName);
        if (!scene) {
          return {
            content: [
              { type: "text", text: `Scene "${sceneName}" が見つかりません` },
            ],
          };
        }

        const bundleId = requireArg<string>(args, "bundleId");
        const apps = await db.getAppsByScene(scene.id!);
        const app = apps.find((a) => a.bundleId === bundleId);
        if (!app) {
          return {
            content: [
              { type: "text", text: `アプリ "${bundleId}" が見つかりません` },
            ],
          };
        }

        await db.updateApp(app.id!, {
          position: {
            x: requireArg<number>(args, "x"),
            y: requireArg<number>(args, "y"),
            width: requireArg<number>(args, "width"),
            height: requireArg<number>(args, "height"),
          },
        });

        return {
          content: [
            { type: "text", text: `アプリ "${bundleId}" の位置を更新しました` },
          ],
        };
      }

      // パッドマッピング
      case "set_pad_mapping": {
        const pad = requireArg<number>(args, "pad");
        if (pad < 1 || pad > 8) {
          return {
            content: [
              { type: "text", text: "パッド番号は1-8の範囲で指定してください" },
            ],
          };
        }

        const contextName = requireArg<string>(args, "contextName");
        const context = await db.getContextByName(contextName);
        if (!context) {
          return {
            content: [
              {
                type: "text",
                text: `Context "${contextName}" が見つかりません`,
              },
            ],
          };
        }

        let sceneId: string | undefined;
        const sceneName = getArg<string>(args, "sceneName");
        if (sceneName) {
          const scenes = await db.getScenesByContext(context.id!);
          const scene = scenes.find((s) => s.name === sceneName);
          if (scene) {
            sceneId = scene.id;
          }
        }

        await db.setPadMapping({
          pad,
          contextId: context.id!,
          sceneId,
        });

        return {
          content: [
            {
              type: "text",
              text: `パッド ${pad} に "${contextName}" を割り当てました`,
            },
          ],
        };
      }

      case "list_pad_mappings": {
        const mappings = await db.getPadMappings();
        const contexts = await db.getContexts();

        const text =
          mappings.length > 0
            ? mappings
                .map((m) => {
                  const context = contexts.find((c) => c.id === m.contextId);
                  return `Pad ${m.pad}: ${context?.name || "unknown"}`;
                })
                .join("\n")
            : "パッドマッピングがありません";

        return { content: [{ type: "text", text }] };
      }

      // ノブマッピング
      case "set_knob_mapping": {
        const knob = requireArg<number>(args, "knob");
        if (knob < 1 || knob > 8) {
          return {
            content: [
              { type: "text", text: "ノブ番号は1-8の範囲で指定してください" },
            ],
          };
        }

        await db.setKnobMapping({
          knob,
          function: requireArg<string>(args, "function"),
        });

        return {
          content: [
            {
              type: "text",
              text: `ノブ ${knob} に "${getArg<string>(args, "function")}" を割り当てました`,
            },
          ],
        };
      }

      // エクスポート
      case "export_config": {
        const kdl = await db.exportToKDL();
        return { content: [{ type: "text", text: kdl }] };
      }

      case "save_config": {
        const path =
          getArg<string>(args, "path") ||
          `${process.env.HOME}/.config/bikeboy/launcher.kdl`;
        const kdl = await db.exportToKDL();

        const fs = await import("node:fs/promises");
        await fs.writeFile(path, kdl, "utf-8");

        return {
          content: [{ type: "text", text: `設定を ${path} に保存しました` }],
        };
      }

      // ユーティリティ
      case "get_running_apps": {
        // macOSで起動中のアプリを取得
        const { exec } = await import("node:child_process");
        const { promisify } = await import("node:util");
        const execAsync = promisify(exec);

        const { stdout } = await execAsync(`
          osascript -e 'tell application "System Events" to get name of every process whose background only is false'
        `);

        const apps = stdout.trim().split(", ");
        return { content: [{ type: "text", text: apps.join("\n") }] };
      }

      case "capture_current_layout": {
        // 現在のウィンドウレイアウトをキャプチャ
        const { exec } = await import("node:child_process");
        const { promisify } = await import("node:util");
        const execAsync = promisify(exec);

        const contextName = requireArg<string>(args, "contextName");
        const sceneName = requireArg<string>(args, "sceneName");

        // Context/Scene確認または作成
        let context = await db.getContextByName(contextName);
        if (!context) {
          context = await db.createContext({ name: contextName });
        }

        const scenes = await db.getScenesByContext(context.id!);
        let scene = scenes.find((s) => s.name === sceneName);
        if (!scene) {
          scene = await db.createScene({
            name: sceneName,
            contextId: context.id!,
          });
        }

        // 既存のアプリを削除
        const existingApps = await db.getAppsByScene(scene.id!);
        for (const app of existingApps) {
          await db.deleteApp(app.id!);
        }

        // ウィンドウ情報を取得
        const { stdout } = await execAsync(`
          osascript -e '
            set output to ""
            tell application "System Events"
              set visibleProcesses to every process whose visible is true
              repeat with proc in visibleProcesses
                set procName to name of proc
                set bundleId to bundle identifier of proc
                try
                  tell proc
                    repeat with win in windows
                      set winName to name of win
                      set winPos to position of win
                      set winSize to size of win
                      set output to output & bundleId & "|" & winName & "|" & (item 1 of winPos) & "|" & (item 2 of winPos) & "|" & (item 1 of winSize) & "|" & (item 2 of winSize) & "\\n"
                    end repeat
                  end tell
                end try
              end repeat
            end tell
            return output
          '
        `);

        const lines = stdout
          .trim()
          .split("\n")
          .filter((l) => l.length > 0);
        let orderIndex = 0;

        for (const line of lines) {
          const [bundleId, windowTitle, x, y, width, height] = line.split("|");
          if (bundleId && x && y && width && height) {
            await db.createApp({
              sceneId: scene.id!,
              bundleId,
              windowTitle: windowTitle || undefined,
              position: {
                x: Number.parseInt(x),
                y: Number.parseInt(y),
                width: Number.parseInt(width),
                height: Number.parseInt(height),
              },
              orderIndex: orderIndex++,
            });
          }
        }

        return {
          content: [
            {
              type: "text",
              text: `${orderIndex}個のウィンドウをキャプチャしました: ${contextName}/${sceneName}`,
            },
          ],
        };
      }

      default:
        return { content: [{ type: "text", text: `Unknown tool: ${name}` }] };
    }
  } catch (error) {
    return {
      content: [{ type: "text", text: `エラー: ${error}` }],
      isError: true,
    };
  }
});

// サーバー起動
async function main() {
  try {
    // DB接続
    await db.connect();

    const transport = new StdioServerTransport();
    await server.connect(transport);

    console.error("bikeboy-mcp サーバー起動");
  } catch (error) {
    console.error("サーバー起動エラー:", error);
    process.exit(1);
  }
}

main();
