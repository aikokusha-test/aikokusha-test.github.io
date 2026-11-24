-- 更新2：年代・判定方法の記録、初回のみ集計、年代別の集計
-- Supabase の SQL Editor に貼り付けて 1 回だけ実行してください。

alter table public.results add column if not exists age    text;
alter table public.results add column if not exists method text;
alter table public.results add column if not exists lean   int;

-- 結果の登録（1端末につき1回目だけを記録）
create or replace function public.submit_result_v2(p_device uuid, p_side text, p_score int, p_age text, p_method text, p_lean int)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_ip   text := coalesce(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1), 'unknown');
  v_hash text := md5(v_ip || 'jh-salt');
begin
  if p_side not in ('left','right') or p_score is null or p_score < 0 or p_score > 100 or p_score % 10 <> 0
     or (p_age is not null and p_age not in ('10代以下','20代','30代','40代','50代','60代','70代以上'))
     or coalesce(p_method,'self') not in ('self','survey')
     or (p_lean is not null and (p_lean < -16 or p_lean > 16)) then
    return 'invalid';
  end if;
  if exists (select 1 from results where device_id = p_device) then
    return 'already';
  end if;
  if (select count(*) from submit_log where ip_hash = v_hash and at > now() - interval '1 hour') >= 30 then
    return 'too_soon';
  end if;
  insert into submit_log(ip_hash) values (v_hash);
  delete from submit_log where at < now() - interval '1 day';
  insert into results(device_id, side, score, age, method, lean, updated_at)
  values (p_device, p_side, p_score, p_age, coalesce(p_method,'self'), p_lean, now());
  return 'ok';
end $$;

-- 集計用：陣営・年代・点数ごとの人数
create or replace function public.get_results_v2()
returns table(side text, age text, score int, n bigint)
language sql stable security definer set search_path = public as $$
  select side, coalesce(age, '不明'), score, count(*) from results group by 1, 2, 3;
$$;

revoke all on function public.submit_result_v2(uuid,text,int,text,text,int), public.get_results_v2() from public;
grant execute on function public.submit_result_v2(uuid,text,int,text,text,int), public.get_results_v2() to anon, authenticated;
