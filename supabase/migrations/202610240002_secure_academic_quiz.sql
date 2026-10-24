-- Preview-only migration for secure academic quiz scoring.
-- Review and apply only to a non-production Supabase branch first.
create or replace function public.start_academic_quiz(p_section_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_session public.test_sessions%rowtype;
  v_questions jsonb;
begin
  if v_user is null then raise exception 'authentication required' using errcode='28000'; end if;
  if not exists (select 1 from public.profiles p where p.id=v_user and coalesce(p.paid_access,false)) then
    raise exception 'payment required' using errcode='42501';
  end if;
  if not exists (
    select 1 from public.academic_sections s
    join public.academic_books b on b.id=s.book_id
    where s.id=p_section_id and s.active and b.active
  ) then raise exception 'section unavailable' using errcode='22023'; end if;
  if not exists (
    select 1 from public.question_bank q
    where q.section_id=p_section_id and q.active and q.source_verified
  ) then raise exception 'no verified questions available' using errcode='P0002'; end if;

  insert into public.test_sessions(student_id,section_id,question_count,status,score,total_points)
  values(v_user,p_section_id,least(10,(select count(*) from public.question_bank q where q.section_id=p_section_id and q.active and q.source_verified)),'in_progress',0,0)
  returning * into v_session;

  insert into public.test_session_questions(session_id,question_id,sort_order)
  select v_session.id, q.id, row_number() over(order by random())::integer
  from (
    select id from public.question_bank
    where section_id=p_section_id and active and source_verified
    order by random() limit 10
  ) q;

  select jsonb_agg(jsonb_build_object(
    'id',q.id,'question_text',q.question_text,'option_a',q.option_a,'option_b',q.option_b,
    'option_c',q.option_c,'option_d',q.option_d,'difficulty',q.difficulty,'points',q.points,
    'sort_order',tsq.sort_order
  ) order by tsq.sort_order) into v_questions
  from public.test_session_questions tsq
  join public.question_bank q on q.id=tsq.question_id
  where tsq.session_id=v_session.id;

  return jsonb_build_object('session_id',v_session.id,'questions',coalesce(v_questions,'[]'::jsonb));
end; $$;

create or replace function public.submit_academic_quiz(p_session_id uuid, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_session public.test_sessions%rowtype;
  v_count integer;
  v_submitted integer;
  v_score integer := 0;
  v_total integer := 0;
  v_correct integer := 0;
  v_item record;
  v_selected smallint;
  v_is_correct boolean;
  v_earned integer;
begin
  if v_user is null then raise exception 'authentication required' using errcode='28000'; end if;
  select * into v_session from public.test_sessions where id=p_session_id and student_id=v_user for update;
  if not found then raise exception 'session not found' using errcode='P0002'; end if;
  if v_session.status <> 'in_progress' then raise exception 'session already submitted' using errcode='22023'; end if;
  if not exists (select 1 from public.profiles p where p.id=v_user and coalesce(p.paid_access,false)) then
    raise exception 'payment required' using errcode='42501';
  end if;
  if jsonb_typeof(p_answers) <> 'array' then raise exception 'answers must be an array' using errcode='22023'; end if;
  select count(*) into v_count from public.test_session_questions where session_id=p_session_id;
  select count(*) into v_submitted from jsonb_array_elements(p_answers);
  if v_count=0 or v_submitted<>v_count then raise exception 'answer count mismatch' using errcode='22023'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_answers) as a(value)
    where not (a.value ? 'question_id') or nullif(a.value->>'question_id','') is null
       or not (a.value ? 'selected_option')
       or coalesce((a.value->>'selected_option') !~ '^[0-3]$', true)
  ) then raise exception 'invalid answer format' using errcode='22023'; end if;
  if (select count(distinct a.value->>'question_id') from jsonb_array_elements(p_answers) as a(value)) <> v_count then
    raise exception 'duplicate answer question' using errcode='22023';
  end if;
  if exists (
    select 1 from public.test_session_answers a
    join public.test_session_questions q on q.id=a.session_question_id
    where q.session_id=p_session_id
  ) then raise exception 'session already has answers' using errcode='22023'; end if;
  if (
    select count(*) from public.test_session_questions tsq
    join public.question_bank q on q.id=tsq.question_id
    join jsonb_array_elements(p_answers) as a(value) on a.value->>'question_id'=q.id::text
    where tsq.session_id=p_session_id
  ) <> v_count then raise exception 'answer question mismatch' using errcode='22023'; end if;

  for v_item in
    select tsq.id as session_question_id, q.id as question_id, q.correct_option, q.points,
           (a.value->>'selected_option')::smallint as selected_option
    from public.test_session_questions tsq
    join public.question_bank q on q.id=tsq.question_id
    join jsonb_array_elements(p_answers) as a(value) on a.value->>'question_id'=q.id::text
    where tsq.session_id=p_session_id
  loop
    v_selected := v_item.selected_option;
    v_is_correct := (v_selected = v_item.correct_option);
    v_earned := case when v_is_correct then v_item.points else 0 end;
    v_score := v_score + v_earned;
    v_total := v_total + v_item.points;
    if v_is_correct then v_correct := v_correct + 1; end if;
    insert into public.test_session_answers(session_question_id,selected_option,is_correct,points_earned)
    values(v_item.session_question_id,v_selected,v_is_correct,v_earned);
  end loop;

  update public.test_sessions set status='completed',score=v_score,total_points=v_total,completed_at=now()
  where id=p_session_id;
  perform set_config('app.allow_server_points_update','on',true);
  update public.profiles set points=coalesce(points,0)+v_score where id=v_user;
  perform set_config('app.allow_server_points_update','off',true);

  return jsonb_build_object('session_id',p_session_id,'score',v_score,'total_points',v_total,'correct_count',v_correct,'question_count',v_count);
end; $$;

create or replace function public.protect_profile_server_fields()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    if new.paid_access is distinct from old.paid_access then raise exception 'paid_access is server-controlled'; end if;
    if new.paid_at is distinct from old.paid_at then raise exception 'paid_at is server-controlled'; end if;
    if new.points is distinct from old.points
       and coalesce(current_setting('app.allow_server_points_update', true), 'off') <> 'on' then
      raise exception 'points are server-controlled';
    end if;
  end if;
  return new;
end; $$;

revoke all on function public.protect_profile_server_fields() from public, anon, authenticated;
revoke all on function public.start_academic_quiz(uuid) from public, anon;
revoke all on function public.submit_academic_quiz(uuid,jsonb) from public, anon;
grant execute on function public.start_academic_quiz(uuid) to authenticated;
grant execute on function public.submit_academic_quiz(uuid,jsonb) to authenticated;

revoke select on public.question_bank from public, anon, authenticated;
grant select (id, section_id, question_text, option_a, option_b, option_c, option_d, difficulty, points, source_page, source_figure, source_text_locked, source_verified, active, created_at)
on public.question_bank to authenticated;


-- Lock student-submitted questions to the pending state; only admins can review.
alter table public.student_question_submissions enable row level security;
drop policy if exists "Students can submit own questions" on public.student_question_submissions;
create policy "Students can submit own questions"
on public.student_question_submissions for insert to authenticated
with check (
  auth.uid() = user_id
  and status = 'pending_review'
  and reviewer_id is null
  and reviewed_at is null
);
drop policy if exists "Students can view own submissions" on public.student_question_submissions;
create policy "Students can view own submissions"
on public.student_question_submissions for select to authenticated
using (auth.uid() = user_id);
drop policy if exists "Admins can review submissions" on public.student_question_submissions;
create policy "Admins can review submissions"
on public.student_question_submissions for all to authenticated
using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));
grant select, insert on public.student_question_submissions to authenticated;
