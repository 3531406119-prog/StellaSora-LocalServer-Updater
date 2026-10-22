import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.MongoDatabase;
import com.mongodb.client.model.Filters;
import com.mongodb.client.model.Updates;
import org.bson.Document;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Map;
import java.util.TreeMap;

/**
 * StellaSora 本地服（Nebula）活动任务进度修复工具。
 *
 * 背景：模拟器目前只创建了活动任务（ActivityTask）的条目，从不写进度，
 *       也没有 ActivityTaskRewardReceive 处理器 —— 所以活动关卡打通了，活动任务永远显示未完成。
 * 本工具做的事：把所有 TaskActivity 里任务的 curProgress 补成 maxProgress（显示为已完成），
 *       并按数据表算出这些任务本该给的奖励，可选地通过 GM 邮件一次性补发。
 *
 * 用法：
 *   java -cp "ActivityTaskFix.class;..\Server\lib\Nebula.jar" ActivityTaskFix --server "D:\Stella Sora" --uid 10003 [--dry] [--send-mail]
 *
 * 注意：请在服务端停止（或玩家离线并重启服务端）时运行，避免内存里的旧数据覆盖。
 */
public class ActivityTaskFix {

    public static void main(String[] args) throws Exception {
        quietLogs();
        forceUtf8Console();
        String server = null;
        String uidArg = null;
        boolean dry = false;
        boolean sendMail = false;

        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if ("--server".equals(a) && i + 1 < args.length) {
                server = args[++i];
            } else if ("--uid".equals(a) && i + 1 < args.length) {
                uidArg = args[++i];
            } else if ("--dry".equals(a)) {
                dry = true;
            } else if ("--send-mail".equals(a)) {
                sendMail = true;
            } else if ("-h".equals(a) || "--help".equals(a)) {
                usage();
                return;
            }
        }
        if (server == null || uidArg == null) {
            usage();
            return;
        }

        File root = new File(server);
        // --server 可以指向包根目录（里面是 Server\）也可以直接指向 Server 目录
        File serverDir = new File(root, "Server");
        if (!new File(serverDir, "config.json").isFile()) {
            serverDir = root;
        }
        File cfgFile = new File(serverDir, "config.json");
        File taskFile = new File(serverDir, "Resources/bin/ActivityTask.json");
        if (!cfgFile.isFile()) {
            System.out.println("[失败] 找不到 " + cfgFile + "（--server 要指向本地服包根目录）");
            return;
        }
        if (!taskFile.isFile()) {
            System.out.println("[失败] 找不到 " + taskFile);
            return;
        }

        JsonObject cfg = JsonParser.parseString(read(cfgFile)).getAsJsonObject();
        JsonObject dbCfg = cfg.getAsJsonObject("accountDatabase");
        String uri = dbCfg.get("uri").getAsString();
        String dbName = dbCfg.get("collection").getAsString();
        JsonObject httpCfg = cfg.has("httpServer") ? cfg.getAsJsonObject("httpServer") : new JsonObject();
        String httpPort = httpCfg.has("bindPort") ? httpCfg.get("bindPort").getAsString() : "5210";
        String httpAddr = httpCfg.has("publicAddress") ? httpCfg.get("publicAddress").getAsString() : "127.0.0.1";
        String adminKey = "";
        if (cfg.has("remoteCommand")) {
            JsonObject rc = cfg.getAsJsonObject("remoteCommand");
            if (rc.has("serverAdminKey")) {
                adminKey = rc.get("serverAdminKey").getAsString();
            }
        }

        JsonObject tasks = JsonParser.parseString(read(taskFile)).getAsJsonObject();
        long uid = Long.parseLong(uidArg);

        System.out.println("本地服目录: " + root.getAbsolutePath());
        System.out.println("数据库: " + uri + " / " + dbName);
        System.out.println("玩家 UID: " + uid);
        System.out.println();

        try (MongoClient mc = MongoClients.create(uri)) {
            MongoDatabase db = mc.getDatabase(dbName);
            MongoCollection<Document> activity = db.getCollection("activity");
            Document doc = activity.find(Filters.eq("_id", uid)).first();
            if (doc == null) {
                System.out.println("[失败] 数据库里没有 uid=" + uid + " 的 activity 记录（先登录一次游戏再运行）");
                return;
            }

            Document activities = (Document) doc.get("activities");
            if (activities == null) {
                System.out.println("[失败] 该玩家的 activity 记录是空的");
                return;
            }

            int total = 0;
            int changed = 0;
            Map<String, Long> reward = new TreeMap<>();

            for (Map.Entry<String, Object> e : activities.entrySet()) {
                Document act = (Document) e.getValue();
                String type = String.valueOf(act.get("_t"));
                if (!type.contains("Task")) {
                    continue;
                }
                Document quests = (Document) act.get("quests");
                if (quests == null) {
                    continue;
                }
                int actChanged = 0;
                for (Map.Entry<String, Object> qe : quests.entrySet()) {
                    Document q = (Document) qe.getValue();
                    total++;
                    long max = number(q.get("maxProgress"));
                    long cur = number(q.get("curProgress"));
                    if (max > 0 && cur != max) {
                        q.put("curProgress", max);
                        changed++;
                        actChanged++;
                    }
                    if (tasks.has(qe.getKey())) {
                        addReward(reward, tasks.getAsJsonObject(qe.getKey()), "Tid1", "Qty1");
                        addReward(reward, tasks.getAsJsonObject(qe.getKey()), "Tid2", "Qty2");
                    }
                }
                System.out.println("活动 " + e.getKey() + " (" + type + "): 任务 " + quests.size() + " 个，改写 " + actChanged + " 个");
            }

            System.out.println();
            System.out.println("合计: 任务 " + total + " 个，改写 " + changed + " 个进度");
            System.out.println("对应奖励: " + reward);

            if (dry) {
                System.out.println("[dry] 只检查，未写入");
            } else if (changed > 0) {
                activity.updateOne(Filters.eq("_id", uid), Updates.set("activities", activities));
                System.out.println("[完成] 已写入数据库（重新登录游戏后生效）");
            } else {
                System.out.println("[跳过] 没有需要改写的任务");
            }

            if (sendMail && !reward.isEmpty()) {
                System.out.println();
                if (adminKey.isEmpty()) {
                    System.out.println("[注意] config.json 里没有 remoteCommand.serverAdminKey，跳过邮件补发");
                } else {
                    StringBuilder sb = new StringBuilder("mail \"活动任务补偿\" \"本地服活动任务进度已补满，对应奖励直接发放。\"");
                    for (Map.Entry<String, Long> r : reward.entrySet()) {
                        sb.append(' ').append(r.getKey()).append(':').append(r.getValue());
                    }
                    sb.append(" @").append(uid);
                    String body = "{\"token\":" + new Gson().toJson(adminKey)
                            + ",\"command\":" + new Gson().toJson(sb.toString()) + "}";
                    String url = "http://" + httpAddr + ":" + httpPort + "/api/command";
                    System.out.println("[邮件] POST " + url);
                    System.out.println("[邮件] 返回: " + post(url, body));
                }
            }
        }
    }

    /** 让中文输出在 cmd/PowerShell 里不乱码（配合 run.cmd 里的 chcp 65001） */
    private static void forceUtf8Console() {
        try {
            System.setOut(new java.io.PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.out), true, StandardCharsets.UTF_8));
            System.setErr(new java.io.PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.err), true, StandardCharsets.UTF_8));
        } catch (Throwable ignored) {
        }
    }
    /** 关掉 mongo 驱动的 INFO 刷屏，只保留 WARN 以上 */
    private static void quietLogs() {
        try {
            org.slf4j.Logger rootLogger = org.slf4j.LoggerFactory.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME);
            if (rootLogger instanceof ch.qos.logback.classic.Logger) {
                ((ch.qos.logback.classic.Logger) rootLogger).setLevel(ch.qos.logback.classic.Level.WARN);
            }
        } catch (Throwable ignored) {
        }
    }
    private static void addReward(Map<String, Long> reward, JsonObject task, String tidKey, String qtyKey) {
        if (!task.has(tidKey) || !task.has(qtyKey)) {
            return;
        }
        String tid = task.get(tidKey).getAsString();
        long qty = number(task.get(qtyKey).getAsLong());
        if (tid.isEmpty() || qty <= 0) {
            return;
        }
        reward.merge(tid, qty, Long::sum);
    }

    private static long number(Object o) {
        if (o instanceof Number) {
            return ((Number) o).longValue();
        }
        if (o instanceof String) {
            try {
                return Long.parseLong((String) o);
            } catch (NumberFormatException ignored) {
                return 0;
            }
        }
        return 0;
    }

    private static String read(File f) throws Exception {
        return new String(Files.readAllBytes(Paths.get(f.getAbsolutePath())), StandardCharsets.UTF_8);
    }

    private static String post(String url, String json) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setRequestMethod("POST");
        c.setConnectTimeout(5000);
        c.setReadTimeout(15000);
        c.setDoOutput(true);
        c.setRequestProperty("Content-Type", "application/json");
        try (OutputStream os = c.getOutputStream()) {
            os.write(json.getBytes(StandardCharsets.UTF_8));
        }
        InputStream in = c.getResponseCode() >= 400 ? c.getErrorStream() : c.getInputStream();
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) {
            bos.write(buf, 0, n);
        }
        in.close();
        return new String(bos.toByteArray(), StandardCharsets.UTF_8);
    }

    private static void usage() {
        System.out.println("用法: java -cp \"<本目录>;<包根目录>\\Server\\lib\\Nebula.jar\" ActivityTaskFix --server \"D:\\Stella Sora\" --uid 10003 [--dry] [--send-mail]");
        System.out.println("  --server     本地服包根目录（含 config.json 与 Server 子目录）");
        System.out.println("  --uid        玩家 UID（服务端日志 login 成功后可见，或 GM 工具里显示）");
        System.out.println("  --dry        只统计不改库");
        System.out.println("  --send-mail  同时用 GM 邮件把对应奖励发给该玩家（需玩家在线）");
    }
}
