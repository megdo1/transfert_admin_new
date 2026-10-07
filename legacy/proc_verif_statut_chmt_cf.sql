CREATE OR REPLACE PROCEDURE SA.proc_verif_statut_chmt_cf(lobjidBds IN table_contr_itm.objid%type, v_num OUT number,v_msg OUT varchar2)
	as
--Verification que les statuts des BdSs concernées sont correctes pour un changement de CU/CF

	cursor BdsResilie is select   i.line_no_txt || ' ' || p.description v1
		from table_contr_itm i, table_mod_level m, table_part_num p
		Where i.contr_itm2mod_level = m.objid
		and m.part_info2part_num = p.objid
		and i.objid = lobjidBds
		and i.x_av_statut_act in ('A Résilier')
		and p.x_av_part_prov_level in ('CF', 'SI')
		and rownum < 2;



recBds table_contr_itm%rowtype;
recPartNum table_part_num%rowtype;
i NUMBER;

BEGIN
	v_num := 0;
	v_msg := '';

	SELECT *
	INTO recBds
	FROM table_contr_itm
	WHERE objid = lobjidBds
	and rownum < 2;

	SELECT p.*
	INTO recPartNum
	FROM table_part_num p, table_mod_level m, table_contr_itm i
	WHERE i.objid = lobjidBds
	and i.contr_itm2mod_level = m.objid
	and m.part_info2part_num = p.objid
	and rownum < 2;

	if recPartNum.x_av_part_prov_level <> 'CF' and recPartNum.x_av_gen_si <> 1 then
		v_num := 14;
		v_msg := 'Il ne devrait pas être possible de faire un transfert administratif pour cet Article: ' || lobjidBds || '.';
	end if;

	-- BdS de statut 'A Résilier'
	if v_num = 0 then
	FOR rec IN BdsResilie LOOP
		v_num := 12;
		v_msg := 'Vous ne pouvez faire de changement de CU/CF sur l''article ' || rec.v1 || ' car il est en cours de résiliation.';
		exit;
	END LOOP;
	end if;

EXCEPTION WHEN OTHERS THEN
	v_num := 100 ;
	v_msg := SQLERRM(SQLCODE);

END proc_verif_statut_chmt_cf;
/
