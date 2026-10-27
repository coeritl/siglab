import { readdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const migrationDir = join(root, 'supabase', 'migrations');
const migrationNames = [
  '20260812_pending_servers.sql',
  '20260812_multiple_assignees.sql',
  '20260812_service_hours.sql',
  '20260813_google_apps_script.sql',
  '20260813_email_reply_updates.sql',
  '20260813_ticket_archiving.sql',
  '20260813_ticket_deletion_audit.sql',
  '20260813_technician_opened_email.sql',
  '20260813_server_reply_notification.sql',
  '20260813_public_ticket_timeline.sql',
  '20260813_production_stabilization.sql',
  '20260813_maintenance_metrics.sql',
  '20260814_lab_computer_count.sql',
  '20260814_reservations.sql',
  '20260814_drop_reservation_block_constraint.sql',
  '20260814_fix_confirm_reservation_status.sql',
  '20260814_public_reservation_schedule.sql',
  '20260814_reservation_admin_edit.sql',
  '20260814_reservation_time_ranges.sql',
  '20260814_support_feedback_url.sql',
  '20260817_completion_confirmation_email.sql',
  '20260818_lab_os_and_staff_edit.sql',
  '20260818_live_chat.sql',
  '20260818_fix_create_ticket_from_chat_ambiguity.sql',
  '20260818_fix_ticket_feedback.sql',
  '20260818_chat_feedback_email.sql',
  '20260819_ifms_schedule_intervals.sql',
  '20260820_staff_reservation_ranges.sql',
  '20260820_optional_reservation_notifications.sql',
  '20260820_restore_completion_feedback_payload.sql',
  '20260821_reservation_production_hardening.sql',
  '20260821_fix_public_reservation_id_ambiguity.sql',
  '20260821_lab_reservation_visibility.sql',
  '20260821_reservation_admin_pagination.sql',
  '20260821_unified_ticket_protocol.sql',
  '20260821_email_payload_by_ticket_status.sql',
  '20260821_email_operations_health.sql',
  '20260826_chat_and_ticket_security_hardening.sql',
  '20260827_public_rpc_rate_limiting.sql',
  '20260828_scope_storage_uploads_to_existing_tickets.sql',
  '20260831_reservation_cleanup.sql',
  '20260831_reservation_conflict_diagnostics.sql',
  '20260831_reservation_search_and_delete.sql',
  '20260831_reservation_cancel_scope.sql',
  '20260831_remove_reservation_operating_hours.sql',
  '20260831_staff_upsert_server.sql',
  '20260831_clear_closed_chat_history.sql',
  '20260901_public_reservation_cancellation_requests.sql',
  '20260901_direct_ticket_completion_and_reservation_cancel.sql',
  '20260901_staff_series_atomic_conflict_check.sql',
  '20260903_chat_online_reminders_and_waiting_email.sql',
  '20261026_siglab_multisector_google_reservations.sql',
  '20261027_siglab_temporary_test_auth.sql',
  '20261027_fix_staff_profile_ambiguity.sql',
];

const discoveredMigrations = (await readdir(migrationDir))
  .filter((name) => name.endsWith('.sql'));
const missing = migrationNames.filter((name) => !discoveredMigrations.includes(name));
const unordered = discoveredMigrations.filter((name) => !migrationNames.includes(name));
if (missing.length || unordered.length) {
  throw new Error(`Revise a ordem das migrations. Ausentes: ${missing.join(', ') || 'nenhuma'}; sem ordem: ${unordered.join(', ') || 'nenhuma'}`);
}

const sources = [
  ['schema.sql', await readFile(join(root, 'supabase', 'schema.sql'), 'utf8')],
  ...(await Promise.all(
    migrationNames.map(async (name) => [
      `migrations/${name}`,
      await readFile(join(migrationDir, name), 'utf8'),
    ]),
  )),
];

const prelude = `-- SIGLAB — instalação inicial consolidada\n-- Gerado automaticamente; execute somente em um projeto Supabase novo.\n-- Projeto esperado: keesciertyonbfqlrqwt\n\n`;
const body = sources
  .map(([name, source]) => `-- -----------------------------------------------------------------------------\n-- ${name}\n-- -----------------------------------------------------------------------------\n${source.trim()}\n`)
  .join('\n');

await writeFile(join(root, 'supabase', 'bootstrap.generated.sql'), prelude + body, 'utf8');
console.log(`Bootstrap gerado com ${sources.length} etapas.`);
