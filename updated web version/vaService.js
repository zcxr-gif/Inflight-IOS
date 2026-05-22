// Shared Supabase client + data helpers for the VA Partnership pages.
// Imported by va-apply, va-admin, va-dashboard, va, and events pages.

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm';

const SUPABASE_URL = 'https://lcgaoiqwwpyqndaucyzu.supabase.co';
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxjZ2FvaXF3d3B5cW5kYXVjeXp1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzIwNjkyOTksImV4cCI6MjA4NzY0NTI5OX0.9TO21knXR_P9E80pea7gUOu-gTjb17sCGk7BYgRRe3U';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON);

const SLUG_MAX = 48;

export function slugify(text) {
    return (text || '')
        .toString()
        .toLowerCase()
        .normalize('NFKD')
        .replace(/[̀-ͯ]/g, '')
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '')
        .slice(0, SLUG_MAX);
}

export async function getSession() {
    const { data } = await supabase.auth.getSession();
    return data?.session || null;
}

export async function getUser() {
    const { data } = await supabase.auth.getUser();
    return data?.user || null;
}

export async function signOut() {
    // signOut can fail when the network is down or the token is already
    // gone server-side. Clear local session either way so the UI doesn't
    // get stuck looking signed in.
    try {
        const { error } = await supabase.auth.signOut();
        if (error) throw error;
    } catch (err) {
        try { await supabase.auth.signOut({ scope: 'local' }); } catch (_) {}
        throw err;
    }
}

export async function updatePassword(newPassword) {
    const { error } = await supabase.auth.updateUser({ password: newPassword });
    if (error) throw error;
}

export async function isStaff() {
    const session = await getSession();
    if (!session) return false;
    const { data, error } = await supabase
        .from('va_staff')
        .select('user_id')
        .eq('user_id', session.user.id)
        .maybeSingle();
    if (error) return false;
    return !!data;
}

export async function getMyApplications() {
    const session = await getSession();
    if (!session) return [];
    const { data } = await supabase
        .from('va_applications')
        .select('*')
        .eq('applicant_id', session.user.id)
        .order('created_at', { ascending: false });
    return data || [];
}

export async function submitApplication(form) {
    const session = await getSession();
    if (!session) throw new Error('Sign in required.');
    const payload = {
        applicant_id: session.user.id,
        va_name: (form.va_name || '').trim(),
        callsign: (form.callsign || '').trim().toUpperCase(),
        ceo_ifc_handle: (form.ceo_ifc_handle || '').trim(),
        hub: (form.hub || '').trim().toUpperCase(),
        fleet: form.fleet?.trim() || null,
        region: form.region?.trim() || null,
        website: form.website?.trim() || null,
        discord: form.discord?.trim() || null,
        logo_url: form.logo_url?.trim() || null,
        pitch: form.pitch?.trim() || null
    };
    if (!payload.va_name || !payload.callsign || !payload.ceo_ifc_handle || !payload.hub) {
        throw new Error('Fill out VA name, callsign, CEO IFC handle, and hub.');
    }
    const { data, error } = await supabase
        .from('va_applications')
        .insert(payload)
        .select()
        .single();
    if (error) throw error;
    return data;
}

export async function listPendingApplications() {
    const { data, error } = await supabase
        .from('va_applications')
        .select('*')
        .eq('status', 'pending')
        .order('created_at', { ascending: true });
    if (error) throw error;
    return data || [];
}

export async function approveApplication(appId, slug) {
    const { data, error } = await supabase.rpc('va_approve_application', {
        app_id: appId,
        va_slug: slug
    });
    if (error) throw error;
    return data;
}

export async function rejectApplication(appId, reason) {
    const { error } = await supabase.rpc('va_reject_application', {
        app_id: appId,
        reason
    });
    if (error) throw error;
}

export async function getVaByCeo() {
    const session = await getSession();
    if (!session) return null;
    const { data } = await supabase
        .from('vas')
        .select('*')
        .eq('ceo_user_id', session.user.id)
        .eq('tombstone', false)
        .maybeSingle();
    return data || null;
}

export async function getVaBySlug(slug) {
    const { data } = await supabase
        .from('vas')
        .select('*')
        .eq('slug', slug)
        .maybeSingle();
    return data || null;
}

export async function listActiveVas() {
    const { data, error } = await supabase
        .from('vas')
        .select('*')
        .eq('tombstone', false)
        .order('name', { ascending: true });
    if (error) throw error;
    return data || [];
}

export async function updateVa(vaId, patch) {
    const { data, error } = await supabase
        .from('vas')
        .update(patch)
        .eq('id', vaId)
        .select()
        .single();
    if (error) throw error;
    return data;
}

export async function listPilots(vaId) {
    const { data } = await supabase
        .from('va_pilots')
        .select('*')
        .eq('va_id', vaId)
        .order('position', { ascending: true });
    return data || [];
}

export async function addPilot(vaId, ifcHandle, rank, position) {
    const payload = {
        va_id: vaId,
        ifc_handle: ifcHandle.trim(),
        rank: rank?.trim() || null,
        position: position ?? 0
    };
    if (!payload.ifc_handle) throw new Error('IFC handle required.');
    const { data, error } = await supabase
        .from('va_pilots')
        .insert(payload)
        .select()
        .single();
    if (error) throw error;
    return data;
}

export async function removePilot(pilotId) {
    const { error } = await supabase.from('va_pilots').delete().eq('id', pilotId);
    if (error) throw error;
}

export async function listEventsForVa(vaId) {
    const { data } = await supabase
        .from('va_events')
        .select('*')
        .eq('va_id', vaId)
        .order('start_at', { ascending: true });
    return data || [];
}

export async function listPendingEvents() {
    const { data, error } = await supabase
        .from('va_events')
        .select('*, vas:va_id (name, callsign, slug, logo_url, trusted)')
        .eq('status', 'pending')
        .order('start_at', { ascending: true });
    if (error) throw error;
    return data || [];
}

export async function listUpcomingApprovedEvents({ server = null, region = null } = {}) {
    let q = supabase
        .from('va_events')
        .select('*, vas:va_id (id, name, callsign, slug, logo_url, region, trusted, tombstone)')
        .eq('status', 'approved')
        .gte('start_at', new Date(Date.now() - 1000 * 60 * 60 * 4).toISOString())
        .order('start_at', { ascending: true })
        .limit(200);
    if (server) q = q.eq('server', server);
    const { data, error } = await q;
    if (error) throw error;
    let rows = data || [];
    rows = rows.filter(r => r.vas && r.vas.tombstone === false);
    if (region) rows = rows.filter(r => r.vas && r.vas.region === region);
    return rows;
}

export async function createEvent(vaId, form) {
    const payload = {
        va_id: vaId,
        name: (form.name || '').trim(),
        start_at: form.start_at,
        end_at: form.end_at || null,
        server: form.server,
        origin_icao: form.origin_icao?.trim().toUpperCase() || null,
        destination_icao: form.destination_icao?.trim().toUpperCase() || null,
        route: form.route?.trim() || null,
        aircraft: form.aircraft?.trim() || null,
        livery: form.livery?.trim() || null,
        briefing: form.briefing?.trim() || null,
        signup_url: form.signup_url?.trim() || null
    };
    if (!payload.name || !payload.start_at || !payload.server) {
        throw new Error('Name, start time, and server are required.');
    }
    if (!payload.origin_icao || !payload.destination_icao) {
        throw new Error('Origin and destination ICAO are required.');
    }
    if (!payload.briefing) {
        throw new Error('Briefing is required.');
    }
    const { data, error } = await supabase
        .from('va_events')
        .insert(payload)
        .select()
        .single();
    if (error) throw error;
    return data;
}

export async function updateEvent(eventId, patch) {
    const { data, error } = await supabase
        .from('va_events')
        .update(patch)
        .eq('id', eventId)
        .select()
        .single();
    if (error) throw error;
    return data;
}

export async function deleteEvent(eventId) {
    const { error } = await supabase.from('va_events').delete().eq('id', eventId);
    if (error) throw error;
}

export async function approveEvent(eventId) {
    const session = await getSession();
    const { error } = await supabase
        .from('va_events')
        .update({
            status: 'approved',
            reviewed_by: session?.user?.id || null,
            reviewed_at: new Date().toISOString()
        })
        .eq('id', eventId);
    if (error) throw error;
}

export async function rejectEvent(eventId, reason) {
    const session = await getSession();
    const { error } = await supabase
        .from('va_events')
        .update({
            status: 'rejected',
            reject_reason: reason || null,
            reviewed_by: session?.user?.id || null,
            reviewed_at: new Date().toISOString()
        })
        .eq('id', eventId);
    if (error) throw error;
}

export async function uploadLogo(file, userId) {
    if (!file || !userId) throw new Error('file and userId required');
    const ext = (file.name.split('.').pop() || 'png').toLowerCase();
    const key = `${userId}/${Date.now()}.${ext}`;
    const { error } = await supabase.storage
        .from('va-logos')
        .upload(key, file, { upsert: false, contentType: file.type });
    if (error) throw error;
    const { data } = supabase.storage.from('va-logos').getPublicUrl(key);
    return data.publicUrl;
}

export function formatEventTime(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    return d.toLocaleString(undefined, {
        weekday: 'short', month: 'short', day: 'numeric',
        hour: '2-digit', minute: '2-digit', timeZoneName: 'short'
    });
}

export function isLive(event) {
    if (!event || event.status !== 'approved') return false;
    const start = new Date(event.start_at).getTime();
    const end = event.end_at ? new Date(event.end_at).getTime() : start + 1000 * 60 * 60 * 3;
    const now = Date.now();
    return now >= start && now <= end;
}
