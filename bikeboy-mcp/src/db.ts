import { StringRecordId, Surreal, Table } from "surrealdb";

// SurrealDB接続設定
const DB_URL = process.env.SURREAL_URL || "ws://localhost:8000/rpc";
const DB_NAMESPACE = process.env.SURREAL_NS || "bikeboy";
const DB_DATABASE = process.env.SURREAL_DB || "launcher";

// データベースインスタンス
let db: Surreal | null = null;

// 接続
export async function connect(): Promise<Surreal> {
  if (db) return db;

  db = new Surreal();

  try {
    await db.connect(DB_URL, {
      namespace: DB_NAMESPACE,
      database: DB_DATABASE,
      authentication: { username: "root", password: "root" },
    });
    console.error(`SurrealDB接続: ${DB_URL} (${DB_NAMESPACE}/${DB_DATABASE})`);

    // スキーマ初期化
    await initSchema();

    return db;
  } catch (error) {
    console.error("SurrealDB接続エラー:", error);
    throw error;
  }
}

// スキーマ初期化
async function initSchema(): Promise<void> {
  if (!db) return;

  // Context テーブル
  await db.query(`
    DEFINE TABLE IF NOT EXISTS context SCHEMAFULL;
    DEFINE FIELD IF NOT EXISTS name ON context TYPE string;
    DEFINE FIELD IF NOT EXISTS defaultScene ON context TYPE option<string>;
    DEFINE FIELD IF NOT EXISTS createdAt ON context TYPE datetime DEFAULT time::now();
    DEFINE FIELD IF NOT EXISTS updatedAt ON context TYPE datetime DEFAULT time::now();
    DEFINE INDEX IF NOT EXISTS idx_context_name ON context FIELDS name UNIQUE;
  `);

  // Scene テーブル
  await db.query(`
    DEFINE TABLE IF NOT EXISTS scene SCHEMAFULL;
    DEFINE FIELD IF NOT EXISTS name ON scene TYPE string;
    DEFINE FIELD IF NOT EXISTS contextId ON scene TYPE record<context>;
    DEFINE FIELD IF NOT EXISTS ledColor ON scene TYPE option<object>;
    DEFINE FIELD IF NOT EXISTS createdAt ON scene TYPE datetime DEFAULT time::now();
    DEFINE FIELD IF NOT EXISTS updatedAt ON scene TYPE datetime DEFAULT time::now();
    DEFINE INDEX IF NOT EXISTS idx_scene_context ON scene FIELDS contextId, name UNIQUE;
  `);

  // App テーブル
  await db.query(`
    DEFINE TABLE IF NOT EXISTS app SCHEMAFULL;
    DEFINE FIELD IF NOT EXISTS sceneId ON app TYPE record<scene>;
    DEFINE FIELD IF NOT EXISTS bundleId ON app TYPE string;
    DEFINE FIELD IF NOT EXISTS windowTitle ON app TYPE option<string>;
    DEFINE FIELD IF NOT EXISTS position ON app TYPE option<object>;
    DEFINE FIELD IF NOT EXISTS orderIndex ON app TYPE int DEFAULT 0;
    DEFINE FIELD IF NOT EXISTS createdAt ON app TYPE datetime DEFAULT time::now();
    DEFINE FIELD IF NOT EXISTS updatedAt ON app TYPE datetime DEFAULT time::now();
  `);

  // PadMapping テーブル
  await db.query(`
    DEFINE TABLE IF NOT EXISTS padMapping SCHEMAFULL;
    DEFINE FIELD IF NOT EXISTS pad ON padMapping TYPE int;
    DEFINE FIELD IF NOT EXISTS contextId ON padMapping TYPE record<context>;
    DEFINE FIELD IF NOT EXISTS sceneId ON padMapping TYPE option<record<scene>>;
    DEFINE FIELD IF NOT EXISTS createdAt ON padMapping TYPE datetime DEFAULT time::now();
    DEFINE INDEX IF NOT EXISTS idx_pad ON padMapping FIELDS pad UNIQUE;
  `);

  // KnobMapping テーブル
  await db.query(`
    DEFINE TABLE IF NOT EXISTS knobMapping SCHEMAFULL;
    DEFINE FIELD IF NOT EXISTS knob ON knobMapping TYPE int;
    DEFINE FIELD IF NOT EXISTS function ON knobMapping TYPE string;
    DEFINE FIELD IF NOT EXISTS createdAt ON knobMapping TYPE datetime DEFAULT time::now();
    DEFINE INDEX IF NOT EXISTS idx_knob ON knobMapping FIELDS knob UNIQUE;
  `);

  console.error("スキーマ初期化完了");
}

// 型定義
export interface Context {
  id?: string;
  name: string;
  defaultScene?: string;
  [key: string]: unknown;
}

export interface Scene {
  id?: string;
  name: string;
  contextId: string;
  ledColor?: { r: number; g: number; b: number };
  [key: string]: unknown;
}

export interface App {
  id?: string;
  sceneId: string;
  bundleId: string;
  windowTitle?: string;
  position?: { x: number; y: number; width: number; height: number };
  orderIndex: number;
  [key: string]: unknown;
}

export interface PadMapping {
  id?: string;
  pad: number;
  contextId: string;
  sceneId?: string;
  [key: string]: unknown;
}

export interface KnobMapping {
  id?: string;
  knob: number;
  function: string;
  [key: string]: unknown;
}

// CRUD操作

// Context
export async function createContext(
  data: Omit<Context, "id">,
): Promise<Context> {
  const db = await connect();
  const result = await db.create(new Table("context")).content(data as Context);
  return (Array.isArray(result) ? result[0] : result) as unknown as Context;
}

export async function getContexts(): Promise<Context[]> {
  const db = await connect();
  const result = await db.select(new Table("context"));
  return (Array.isArray(result) ? result : [result]) as unknown as Context[];
}

export async function getContextByName(name: string): Promise<Context | null> {
  const db = await connect();
  const results = await db.query<[Context[]]>(
    "SELECT * FROM context WHERE name = $name",
    { name },
  );
  return results[0]?.[0] || null;
}

export async function updateContext(
  id: string,
  data: Partial<Context>,
): Promise<Context> {
  const db = await connect();
  const result = await db
    .update(new StringRecordId(id))
    .merge({ ...data, updatedAt: new Date() });
  return (Array.isArray(result) ? result[0] : result) as unknown as Context;
}

export async function deleteContext(id: string): Promise<void> {
  const db = await connect();
  await db.delete(new StringRecordId(id));
}

// Scene
export async function createScene(data: Omit<Scene, "id">): Promise<Scene> {
  const db = await connect();
  const result = await db.create(new Table("scene")).content(data as Scene);
  return (Array.isArray(result) ? result[0] : result) as unknown as Scene;
}

export async function getScenesByContext(contextId: string): Promise<Scene[]> {
  const db = await connect();
  const results = await db.query<[Scene[]]>(
    "SELECT * FROM scene WHERE contextId = $contextId",
    { contextId },
  );
  return results[0] || [];
}

export async function updateScene(
  id: string,
  data: Partial<Scene>,
): Promise<Scene> {
  const db = await connect();
  const result = await db
    .update(new StringRecordId(id))
    .merge({ ...data, updatedAt: new Date() });
  return (Array.isArray(result) ? result[0] : result) as unknown as Scene;
}

export async function deleteScene(id: string): Promise<void> {
  const db = await connect();
  await db.delete(new StringRecordId(id));
}

// App
export async function createApp(data: Omit<App, "id">): Promise<App> {
  const db = await connect();
  const result = await db.create(new Table("app")).content(data as App);
  return (Array.isArray(result) ? result[0] : result) as unknown as App;
}

export async function getAppsByScene(sceneId: string): Promise<App[]> {
  const db = await connect();
  const results = await db.query<[App[]]>(
    "SELECT * FROM app WHERE sceneId = $sceneId ORDER BY orderIndex",
    { sceneId },
  );
  return results[0] || [];
}

export async function updateApp(id: string, data: Partial<App>): Promise<App> {
  const db = await connect();
  const result = await db
    .update(new StringRecordId(id))
    .merge({ ...data, updatedAt: new Date() });
  return (Array.isArray(result) ? result[0] : result) as unknown as App;
}

export async function deleteApp(id: string): Promise<void> {
  const db = await connect();
  await db.delete(new StringRecordId(id));
}

// PadMapping
export async function setPadMapping(
  data: Omit<PadMapping, "id">,
): Promise<PadMapping> {
  const db = await connect();
  // 既存のマッピングを削除してから作成
  await db.query("DELETE FROM padMapping WHERE pad = $pad", { pad: data.pad });
  const result = await db
    .create(new Table("padMapping"))
    .content(data as PadMapping);
  return (Array.isArray(result) ? result[0] : result) as unknown as PadMapping;
}

export async function getPadMappings(): Promise<PadMapping[]> {
  const db = await connect();
  const result = await db.select(new Table("padMapping"));
  return (Array.isArray(result) ? result : [result]) as unknown as PadMapping[];
}

// KnobMapping
export async function setKnobMapping(
  data: Omit<KnobMapping, "id">,
): Promise<KnobMapping> {
  const db = await connect();
  await db.query("DELETE FROM knobMapping WHERE knob = $knob", {
    knob: data.knob,
  });
  const result = await db
    .create(new Table("knobMapping"))
    .content(data as KnobMapping);
  return (Array.isArray(result) ? result[0] : result) as unknown as KnobMapping;
}

export async function getKnobMappings(): Promise<KnobMapping[]> {
  const db = await connect();
  const result = await db.select(new Table("knobMapping"));
  return (Array.isArray(result)
    ? result
    : [result]) as unknown as KnobMapping[];
}

// 全設定をエクスポート（KDL形式）
export async function exportToKDL(): Promise<string> {
  const contexts = await getContexts();
  const padMappings = await getPadMappings();
  const knobMappings = await getKnobMappings();

  let kdl = "// bikeboy-launcher 設定ファイル\n// Generated by bikeboy-mcp\n\n";

  // Contexts
  for (const context of contexts) {
    const scenes = await getScenesByContext(context.id!);

    kdl += `context "${context.name}"`;
    if (context.defaultScene) {
      kdl += ` default="${context.defaultScene}"`;
    }
    kdl += " {\n";

    for (const scene of scenes) {
      kdl += `    scene "${scene.name}"`;
      if (scene.ledColor) {
        kdl += ` led-r=${scene.ledColor.r} led-g=${scene.ledColor.g} led-b=${scene.ledColor.b}`;
      }
      kdl += " {\n";

      const apps = await getAppsByScene(scene.id!);
      for (const app of apps) {
        kdl += `        app "${app.bundleId}"`;
        if (app.windowTitle) {
          kdl += ` window="${app.windowTitle}"`;
        }
        if (app.position) {
          kdl += " {\n";
          kdl += `            position x=${app.position.x} y=${app.position.y} width=${app.position.width} height=${app.position.height}\n`;
          kdl += "        }\n";
        } else {
          kdl += "\n";
        }
      }

      kdl += "    }\n";
    }

    kdl += "}\n\n";
  }

  // Pad mappings
  kdl += "// パッドマッピング\n";
  for (const mapping of padMappings) {
    const context = contexts.find((c) => c.id === mapping.contextId);
    if (context) {
      kdl += `pad ${mapping.pad} context="${context.name}"`;
      if (mapping.sceneId) {
        kdl += ` scene="default"`;
      }
      kdl += "\n";
    }
  }

  // Knob mappings
  kdl += "\n// ノブマッピング\n";
  for (const mapping of knobMappings) {
    kdl += `knob ${mapping.knob} "${mapping.function}"\n`;
  }

  return kdl;
}
