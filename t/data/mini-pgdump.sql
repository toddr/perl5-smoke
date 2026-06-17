--
-- Minimal pg_dump fixture for t/04-import-pgdump.t
-- Two reports, one failure, enough to exercise all row handlers.
--

COPY public.smoke_config (id, md5, config) FROM stdin;
1	5e8ff9bf55ba3508199f22e37b17f4c8	-Duse64bitall -Duseshrplib
2	a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6	-DEBUGGING
\.

COPY public.report (id, sconfig_id, duration, config_count, reporter, reporter_version, smoke_perl, smoke_revision, smoke_version, smoker_version, smoke_date, perl_id, git_id, git_describe, applied_patches, hostname, architecture, osname, osversion, cpu_count, cpu_description, username, test_jobs, lc_all, lang, user_note, skipped_tests, harness_only, harness3opts, summary, smoke_branch, plevel, log_file, out_file, manifest_msgs, compiler_msgs, nonfatal_msgs) FROM stdin;
1	1	3600	4	Test::Smoke	1.80	/usr/bin/perl	\N	1.80	\N	2024-06-15 14:30:00+02	v5.42.0	gff5bbe677c9	v5.42.0	\N	testhost	x86_64/linux	linux	6.1.0	4	Intel Core i7	tester	4	\N	\N	\N	\N	0	\N	PASS	blead	5.042000zzz000	\N	\N	\N	\N	\N
2	2	1800	2	Test::Smoke	1.78	/usr/local/bin/perl	\N	1.78	\N	2024-06-16 09:00:00+00	v5.40.2	abc1234567de	v5.40.2	\N	smoker2	aarch64/linux	linux	5.15.0	8	ARM Cortex-A76	admin	8	en_US.UTF-8	\N	test note with\ttab	\N	0	\N	FAIL(F)	blead	5.040002zzz000	\N	\N	\N	\N	\N
\.

COPY public.config (id, report_id, arguments, debugging, started, duration, cc, ccversion) FROM stdin;
1	1	-Dusethreads	D	2024-06-15 13:00:00+02	900	gcc	12.3.0
2	2	-Dusethreads -Duse64bitall	D	2024-06-16 08:30:00+00	450	clang	15.0.0
\.

COPY public.result (id, config_id, io_env, locale, summary, statistics, stat_cpu_time, stat_tests) FROM stdin;
1	1	perlio	\N	PASS	Files=2766, Tests=1234567	45.2	1234567
2	2	stdio	en_US.UTF-8	FAIL(F)	Files=2766, Tests=1234000	60.1	1234000
\.

COPY public.failure (id, test, status, extra) FROM stdin;
1	t/op/die.t	FAILED	\N
\.

COPY public.failures_for_env (result_id, failure_id) FROM stdin;
2	1
\.

COPY public.tsgateway_config (id, name, value) FROM stdin;
1	dbversion	4
\.
