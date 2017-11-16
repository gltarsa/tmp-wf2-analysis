select * from inventory_parts where id = (seexitlect max(id) from inventory_parts);
select * from payroll_invoice_items where id = (select max(id) from payroll_invoice_items);
select * from payroll_invoice_item_parts where id = (select max(id) from payroll_invoice_item_parts);
select * from dispatching_service_codes where id = (select max(id) from dispatching_service_codes);
select * from payroll_invoice_item_service_codes where id = (select max(id) from payroll_invoice_item_service_codes);
select * from payroll_invoice_item_pay_grades where id = (select max(id) from payroll_invoice_item_pay_grades);
select * from payroll_pay_grade_versions where id = (select max(id) from payroll_pay_grade_versions);