CREATE OR REPLACE PROCEDURE SA.verif_cf(CF_objid IN table_site.objid%type, CU_objid IN table_site.objid%type, contrat_objid IN table_contract.objid%type, v_num OUT number,v_msg OUT varchar2)
	as
--Verification qu'un mode de règlement,
--un cycle de facturation et un délai de paiement
--sont définis pour tous les sites de facturation

	cursor C5 is select   table_site.site_id || ' ' ||table_site.name v1
		from 	table_site
		Where (nvl(table_site.x_av_bill_pay_method,'Sélectionner') = 'Sélectionner'
		or nvl(table_site.x_av_bill_freq,'Sélectionner') = 'Sélectionner'
		or nvl(table_site.x_av_bill_month,'Sélectionner') = 'Sélectionner'
		or nvl(table_site.x_av_bill_cycle,'Sélectionner') = 'Sélectionner'
		or nvl(table_site.x_av_bill_delay,'Sélectionner') = 'Sélectionner')
		and rownum < 2
		and table_site.objid = CF_objid;



recCF table_site%rowtype;
recCU table_site%rowtype;
recContrat table_contract%rowtype;
i NUMBER;
addr VARCHAR2(200);
ville VARCHAR2(40);
cp VARCHAR2(20);
pays VARCHAR2(40);

BEGIN
	v_num := 0;
	v_msg := '';

	SELECT *
	INTO recCF
	FROM table_site
	WHERE objid = CF_objid
	and rownum < 2;

	SELECT *
	INTO recCU
	FROM table_site
	WHERE objid = CU_objid
	and rownum < 2;

	SELECT *
	INTO recContrat
	FROM table_contract
	WHERE objid = contrat_objid
	and rownum < 2;

	-- La date de début
	if to_date(recCF.x_av_start_date) > sysdate then
		v_num := 1;
		v_msg := 'La date de début d''activité du CF site ' || recCF.name || ' est supérieure à la date du jour.';
	end if;
	if v_num = 0 then
	if to_date(recCU.x_av_start_date) > sysdate then
		v_num := 10;
		v_msg := 'La date de début d''activité du CU site ' || recCU.name || ' est supérieure à la date du jour.';
	end if;
	end if;

	if v_num = 0 then
	-- Destinataire Principal de la Facture (CF)
	BEGIN
		select 1 into i
		from table_site s, table_contact_role r
		where r.CONTACT_ROLE2SITE = s.objid
		and r.ROLE_NAME = 'Destinataire principal de la facture'
		and s.objid = CF_objid
		and rownum < 2;

	EXCEPTION WHEN NO_DATA_FOUND THEN
		v_num := 2;
		v_msg := 'Erreur Utilisateur - Aucun contact, avec le role ''Destinataire Principal de la Facture'', n''est associé au CF site ' || recCF.site_id || '.';
	END;
	end if;

	-- type Distributeur
	if v_num = 0 then
	if recCF.site_type = 'DIST' then
		v_num := 3;
		v_msg := 'Erreur utilisateur, le CF ' || recCF.site_id || ' ne peut pas être un site distributeur';
	end if;
	end if;
	if v_num = 0 then
	if recCU.site_type = 'DIST' then
		v_num := 9;
		v_msg := 'Erreur utilisateur, le CU ' || recCU.site_id || ' ne peut pas être un site distributeur';
	end if;
	end if;

	-- RCS
	if v_num = 0 then
	if recCF.x_av_rcs_contrat is null then
		update table_site
		set x_av_rcs_contrat = recContrat.x_av_rcs
		where objid = recCF.objid;
	elsif recCF.x_av_rcs_contrat <> recContrat.x_av_rcs then
		v_num := 4;
		v_msg := 'Erreur utilisateur, le RCS neuf cegetel du CF sélectionné '  || recCF.site_id || ' est different du RCS contrat';
	end if;
	end if;

	if v_num = 0 then
	if recCU.x_av_rcs_contrat is null then
		update table_site
		set x_av_rcs_contrat = recContrat.x_av_rcs
		where objid = recCU.objid;
	elsif recCU.x_av_rcs_contrat <> recContrat.x_av_rcs then
		v_num := 7;
		v_msg := 'Erreur utilisateur, le RCS neuf cegetel du CU sélectionné '  || recCU.site_id || ' est different du RCS contrat';
	end if;
	end if;

	-- donnée de facturation
	if v_num = 0 then
	FOR rec IN C5 LOOP
		v_num := 5 ;
		v_msg := 'Au moins une donnée de facturation (cycle de facturation, fréquence de facturation, mois de facturation, délai de paiement, mode de paiement) n''est pas définie pour le site ' || rec.v1 || '.';
		exit;
	END LOOP;
	end if;

	-- donnée de l'adresse
	if v_num = 0 then
	BEGIN
		select a.address, a.city , a.zipcode , c.name
		into addr, ville, cp, pays
		from table_site s, table_address a, table_country c
		where s.CUST_BILLADDR2ADDRESS = a.objid
		and c.objid = a.ADDRESS2COUNTRY
		and s.objid = CF_objid
		and rownum < 2;

		if nvl(length(addr),0) < 1 or nvl(length(ville),0) < 1 or nvl(length(cp),0) < 1 or nvl(length(pays),0) < 1 then
			v_num := 11 ;
			v_msg := 'L''adresse de facturation n''est pas correctement définie pour le CF site'  || recCF.site_id || '.';
		end if;

	EXCEPTION WHEN NO_DATA_FOUND THEN
		v_num := 11 ;
		v_msg := 'L''adresse de facturation n''est pas correctement définie pour le CF site'  || recCF.site_id || '.';
	END;
	end if;

	-- role de facturation
	if v_num = 0 then
	BEGIN
		select 1 into i
		from table_site s, table_bus_org b, table_bus_site_role r
		where s.objid = CF_objid
		and s.objid = r.bus_site_role2site
		and b.objid = r.bus_site_role2bus_org
		and r.ROLE_NAME = 'Facturation'
		and b.objid <> -2
		and rownum < 2;
	EXCEPTION WHEN NO_DATA_FOUND THEN
		v_num := 6;
		v_msg := 'Le CF sélectionné '  || recCF.site_id || ' n''a de rôle de facturation vis à vis d''aucune orgnaisation.';
	END;
	end if;

	if v_num = 0 then
	BEGIN
		select count(*)
		into i
		from table_bus_org bcf, table_site cf, table_bus_site_role rcf,
		table_bus_org bcu, table_site cu, table_bus_site_role rcu
		where bcf.objid = rcf.BUS_SITE_ROLE2BUS_ORG
		and cf.objid = rcf.BUS_SITE_ROLE2SITE
		and rcf.ROLE_NAME = 'Facturation'
		and bcf.objid <> -2
		and bcu.objid = rcu.BUS_SITE_ROLE2BUS_ORG
		and cu.objid = rcu.BUS_SITE_ROLE2SITE
		and rcu.ROLE_NAME = 'Facturation'
		and bcu.objid <> -2
		and bcf.objid = bcu.objid
		and cu.objid = CU_objid
		and cf.objid = CF_objid
		and rownum < 2;

		if i > 1 then
			v_num := 8;
			v_msg := 'Les CU et CF ont un rôle de facturation vis à vis de plus d''une organisation.';
		end if;
		if i < 1 then
			v_num := 8;
			v_msg := 'Le CU '  || recCU.site_id || ' n''a pas de rôle de facturation vis à vis de la même organisation que le CF sélectionné '  || recCF.site_id || '.';
		end if;
	END;
	end if;


EXCEPTION WHEN OTHERS THEN
	v_num := 100 ;
	v_msg := SQLERRM(SQLCODE);

END verif_cf;
/
