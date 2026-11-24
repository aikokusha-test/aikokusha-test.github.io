-- 左翼vs右翼 日本史テスト：Supabase の SQL Editor に貼り付けて 1 回実行してください。

-- 1端末につき最新の結果を1件だけ保存
create table if not exists public.results (
  device_id  uuid primary key,
  side       text not null check (side in ('left','right')),
  score      int  not null check (score between 0 and 100 and score % 10 = 0),
  updated_at timestamptz not null default now()
);

-- 連投対策用の記録（IPアドレスはハッシュ化して保存）
create table if not exists public.submit_log (
  ip_hash text not null,
  at      timestamptz not null default now()
);
create index if not exists submit_log_ip_at on public.submit_log (ip_hash, at);

-- テーブルへの直接アクセスは全面禁止。下の関数経由でのみ読み書きできる
alter table public.results    enable row level security;
alter table public.submit_log enable row level security;
revoke all on public.results, public.submit_log from anon, authenticated;

-- 結果の登録
create or replace function public.submit_result(p_device uuid, p_side text, p_score int)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_ip   text := coalesce(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1), 'unknown');
  v_hash text := md5(v_ip || 'jh-salt');
  v_last timestamptz;
begin
  if p_side not in ('left','right') or p_score is null or p_score < 0 or p_score > 100 or p_score % 10 <> 0 then
    return 'invalid';
  end if;
  -- 同じ端末は1分に1回まで
  select updated_at into v_last from results where device_id = p_device;
  if v_last is not null and v_last > now() - interval '1 minute' then
    return 'too_soon';
  end if;
  -- 同じIPからは1時間に30回まで
  if (select count(*) from submit_log where ip_hash = v_hash and at > now() - interval '1 hour') >= 30 then
    return 'too_soon';
  end if;
  insert into submit_log(ip_hash) values (v_hash);
  delete from submit_log where at < now() - interval '1 day';
  insert into results(device_id, side, score, updated_at) values (p_device, p_side, p_score, now())
  on conflict (device_id) do update set side = excluded.side, score = excluded.score, updated_at = now();
  return 'ok';
end $$;

-- 陣営ごとの集計（人数・中央値・最高点）
create or replace function public.get_standings()
returns table(side text, n bigint, median numeric, top int)
language sql stable security definer set search_path = public as $$
  select side, count(*),
         round(percentile_cont(0.5) within group (order by score)::numeric, 1),
         max(score)
  from results group by side;
$$;

revoke all on function public.submit_result(uuid,text,int), public.get_standings() from public;
grant execute on function public.submit_result(uuid,text,int), public.get_standings() to anon, authenticated;
