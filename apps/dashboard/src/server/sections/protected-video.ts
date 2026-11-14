import { windowFor, type RangeKey } from "../../lib/range";
import { num, query, str } from "../clickhouse";
import { APP_SOURCE, prop, since } from "../sql";
import { PROTECTED_VIDEO_COUNTS, protectedVideoRows } from "./protected-video-rows";

const CDM = "setting_widevine_installed";

export async function healthProtectedVideo(range: RangeKey, signal?: AbortSignal) {
  const w = windowFor(range);
  const sums = PROTECTED_VIDEO_COUNTS.map((field) => `sum(toFloat64OrZero(properties['${field}']))`).join(", ");
  const [usage, cdm] = await Promise.all([
    query(
      `SELECT if(${prop("$app_version")} = '', 'unknown', ${prop("$app_version")}) AS v, uniq(distinct_id), ${sums}
       FROM telemetry.events
       WHERE event = 'usage_counts' AND ${APP_SOURCE} AND ${since(w.start)}
       GROUP BY GROUPING SETS ((v), ())`,
      signal,
    ),
    query(
      `SELECT countIf(installed = 'true'), count()
       FROM (
         SELECT distinct_id, argMax(properties['${CDM}'], timestamp) AS installed
         FROM telemetry.events
         WHERE event = 'settings_snapshot' AND ${APP_SOURCE} AND ${since(w.start)} AND properties['${CDM}'] != ''
         GROUP BY distinct_id
       )`,
      signal,
    ),
  ]);
  return protectedVideoRows(
    usage.map((r) => ({
      version: str(r[0]),
      people: num(r[1]),
      attempts: num(r[2]),
      successes: num(r[3]),
      failures: num(r[4]),
      refusals: num(r[5]),
      access: num(r[6]),
      createKeys: num(r[7]),
      licence: num(r[8]),
      keystatus: num(r[9]),
    })),
    { installed: num(cdm[0]?.[0]), reported: num(cdm[0]?.[1]) },
  );
}
