-- Cached vs uncached prompt tokens per model, per day, from the request log.
-- LiteLLM stores each request's full usage block in metadata->'usage_object';
-- prompt_tokens includes the cached ones, so uncached = prompt - cached.
SELECT
  "startTime"::date                                   AS day,
  model,
  count(*)                                            AS requests,
  sum(prompt_tokens)                                  AS prompt_tokens,
  sum(cached)                                         AS cached_tokens,
  sum(prompt_tokens - cached)                         AS uncached_tokens,
  sum(cache_write)                                    AS cache_write_tokens,
  round(100.0 * sum(cached) / nullif(sum(prompt_tokens), 0), 1) AS cached_pct,
  sum(completion_tokens)                              AS completion_tokens,
  round(sum(spend)::numeric, 4)                       AS spend_usd
FROM (
  SELECT *,
    coalesce((metadata #>> '{usage_object,prompt_tokens_details,cached_tokens}')::int,
             (metadata #>> '{usage_object,cache_read_input_tokens}')::int, 0) AS cached,
    coalesce((metadata #>> '{usage_object,prompt_tokens_details,cache_write_tokens}')::int,
             (metadata #>> '{usage_object,cache_creation_input_tokens}')::int, 0) AS cache_write
  FROM "LiteLLM_SpendLogs"
) s
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
