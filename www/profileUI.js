/**
 * ProfileUI — Soft Premium Dashboard Interface
 *
 * Redesigned shell:
 * • Floating dock (bottom-center) replaces the laggy hover-expand sidebar
 * • Slim top utility strip (theme cycle, density toggle, user chip, close)
 * • Warm-neutral palette with a single gentle caramel accent
 *
 * Performance:
 * • Tab switches only re-render the content area, not the full shell
 * • No fullscreen backdrop-filter; modal sits on a dimmed plate
 * • Specific transitions only (opacity / transform / background-color)
 * • Skeleton uses a soft pulse rather than infinite shimmer gradient
 *
 * Premium Feature Updates:
 * • Live Watchlist Autocomplete: Indexes WebSocket streams for real-time pilot search.
 * • Dispatch Management: Edit and Delete capabilities for filed flight plans.
 * • Dispatch Automation: Predictive EET (Estimated Elapsed Time) calculation.
 * • Aircraft Selection: Dash-proof ICAO routing integration.
 */

import { CareerModule } from './careerModule.js';
import { PredictiveAirspaceNetwork } from './PredictiveQueueManager.js';
import { socketDataHub } from './SocketDataHub.js';
import { MobileDashboardUI } from './MobileDashboardUI.js';
import { FlightDispatchService } from './FlightDispatchService.js';
import { TelemetryAnalyticsEngine } from './TelemetryAnalyticsEngine.js';
import { AircraftViewer3D } from './AircraftViewer3D.js';
import { AirportViewer3D } from './AirportViewer3D.js';
import { FlightDispatchUI } from './FlightDispatchUI.js';

const AIRCRAFT_SELECTION_LIST = [
    // Airbus
    { value: 'A318', name: 'Airbus A318-100' },
    { value: 'A319', name: 'Airbus A319-100' },
    { value: 'A320', name: 'Airbus A320-200' },
    { value: 'A20N', name: 'Airbus A320neo' },
    { value: 'A321', name: 'Airbus A321-200' },
    { value: 'A21N', name: 'Airbus A321neo' },
    { value: 'A333', name: 'Airbus A330-300' },
    { value: 'A339', name: 'Airbus A330-900neo' },
    { value: 'A346', name: 'Airbus A340-600' },
    { value: 'A359', name: 'Airbus A350-900' },
    { value: 'A388', name: 'Airbus A380-800' },
    // Boeing
    { value: 'B712', name: 'Boeing 717-200' },
    { value: 'B737', name: 'Boeing 737-700' },
    { value: 'B738', name: 'Boeing 737-800' },
    { value: 'B739', name: 'Boeing 737-900' },
    { value: 'B38M', name: 'Boeing 737 MAX 8' },
    { value: 'B742', name: 'Boeing 747-200B' },
    { value: 'B744', name: 'Boeing 747-400' },
    { value: 'B748', name: 'Boeing 747-8' },
    { value: 'B752', name: 'Boeing 757-200' },
    { value: 'B763', name: 'Boeing 767-300ER' },
    { value: 'B772', name: 'Boeing 777-200ER' },
    { value: 'B77L', name: 'Boeing 777-200LR' },
    { value: 'B77W', name: 'Boeing 777-300ER' },
    { value: 'B788', name: 'Boeing 787-8' },
    { value: 'B789', name: 'Boeing 787-9' },
    { value: 'B78X', name: 'Boeing 787-10' },
    // Bombardier (CRJ)
    { value: 'CRJ2', name: 'Bombardier CRJ-200' },
    { value: 'CRJ7', name: 'Bombardier CRJ-700' },
    { value: 'CRJ9', name: 'Bombardier CRJ-900' },
    { value: 'CRJX', name: 'Bombardier CRJ-1000' },
    // De Havilland
    { value: 'DH8D', name: 'De Havilland Dash 8 Q400' },
    // Embraer
    { value: 'E175', name: 'Embraer E175' },
    { value: 'E190', name: 'Embraer E190' },
    // McDonnell Douglas
    { value: 'DC10', name: 'McDonnell Douglas DC-10' },
    { value: 'MD11', name: 'McDonnell Douglas MD-11' },
];

export const ProfileUI = {
    _supabase: null,
    _isOpen: false,
    _injected: false,
    _shellBuilt: false, // Tracks whether the persistent dock + top strip are mounted
    _activeTab: 'dashboard',
    _currentUser: null,
    _theme: 'light',
    _density: 'cozy', // 'cozy' | 'compact'
    _timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    _flightPlansData: [],
    _editingFlightId: null, // Tracks active flight plan being edited
    
    // Premium Caching
    // Premium Caching
    _airportCache: null, 
    _aircraftMap: new Map(),
    _liveryMap: new Map(),

    // Premium Telemetry Integration

    // Premium Telemetry Integration
    _airspaceNetwork: null,
    _airspaceRefreshTimer: null,
    _liveFlights: [],
    _currentAllFlights: [], // Stores real-time global flight data for autocomplete
    _socketUnsubscribe: null,

    // ── 3D Hero Viewer (CesiumJS forward-view, behind the live flight card) ─
    // Tracks which flight the currently-mounted Cesium viewer was initialised
    // for, so we can preserve its scene across DOM rebuilds and only re-init
    // when the active flight actually changes.
    _3dViewerHostKey: null,
    _active3DFlightId: null,

    _subscription: {
        status: 'Active',
        plan: 'Pro Access',
        price: '$1.99 / month'
    },
    // Store live IF data
    _ifData: {
        loading: false,
        userId: null,
        stats: null,
        logbook: [],
        logbookTotal: 0,
        activeHistory: null,
        error: null
    },
    _backendUrl: window.APP_CONFIG?.backendUrl || 'https://site--acars-backend--6dmjph8ltlhv.code.run',

    // ── Pilot Watchlist ──────────────────────────────────────────────────────
    _watchlist: [],
    _watchedPilotStatus: {},
    _prevWatchedStatus: {},

    // ── Cross-device User Preferences (Supabase persisted) ───────────────────
    _userPrefs: {
        notification_watchlist_enabled: true,
        cached_if_stats: null,
        cached_if_at: null,
    },

    // ── Personalization & Localization state ─────────────────────────────────
    _locale:    'en',          // 'en' | 'es' | 'pt-BR' | 'fr' | 'de' | 'ja'
    _accent:    'caramel',     // key into _ACCENT_PRESETS
    _bio:       '',            // pilot tagline / bio (max ~140 chars)
    _coverUrl:  '',            // optional cover banner image URL
    _dockOrder: null,          // array of tab ids overriding default order, or null

    // Default tab order — _dockOrder may override this
    _DEFAULT_DOCK_ORDER: ['dashboard', 'career-deep-dive', 'airspace-intel', 'flight-plan', 'watchlist', 'settings'],

    // Accent color presets — applied as CSS variable overrides on the wrapper layer.
    // Each preset supplies the same four vars used throughout the stylesheet.
    _ACCENT_PRESETS: {
        caramel: { label: 'Caramel', light: { c: '#b88553', h: '#a87543', s: 'rgba(184,133,83,0.10)',  g: 'rgba(184,133,83,0.18)'  },
                                     dark:  { c: '#d4a574', h: '#e0b384', s: 'rgba(212,165,116,0.14)', g: 'rgba(212,165,116,0.22)' } },
        ocean:   { label: 'Ocean',   light: { c: '#3b7ea8', h: '#2f6c93', s: 'rgba(59,126,168,0.10)',  g: 'rgba(59,126,168,0.18)'  },
                                     dark:  { c: '#5fa8d3', h: '#7ab8de', s: 'rgba(95,168,211,0.14)', g: 'rgba(95,168,211,0.22)'  } },
        forest:  { label: 'Forest',  light: { c: '#3f8c5a', h: '#327547', s: 'rgba(63,140,90,0.10)',   g: 'rgba(63,140,90,0.18)'   },
                                     dark:  { c: '#7bbf91', h: '#8fcca3', s: 'rgba(123,191,145,0.14)',g: 'rgba(123,191,145,0.22)' } },
        rose:    { label: 'Rose',    light: { c: '#c25a7e', h: '#a8466a', s: 'rgba(194,90,126,0.10)',  g: 'rgba(194,90,126,0.18)'  },
                                     dark:  { c: '#e08aa8', h: '#e89cb6', s: 'rgba(224,138,168,0.14)',g: 'rgba(224,138,168,0.22)' } },
        violet:  { label: 'Violet',  light: { c: '#7e57c2', h: '#6845a8', s: 'rgba(126,87,194,0.10)',  g: 'rgba(126,87,194,0.18)'  },
                                     dark:  { c: '#b287d9', h: '#c099e0', s: 'rgba(178,135,217,0.14)',g: 'rgba(178,135,217,0.22)' } },
        slate:   { label: 'Slate',   light: { c: '#5a6878', h: '#475363', s: 'rgba(90,104,120,0.10)', g: 'rgba(90,104,120,0.18)'  },
                                     dark:  { c: '#94a3b3', h: '#a8b5c2', s: 'rgba(148,163,179,0.14)',g: 'rgba(148,163,179,0.22)' } },
    },

    // ── Localization (i18n) ──────────────────────────────────────────────────
    // Strings the UI renders. Unknown keys fall back to English; unknown locales
    // fall back to English. Adding a new locale is purely additive.
    _LOCALES: {
        en:      { label: 'English',           flag: '🇬🇧' },
        es:      { label: 'Español',           flag: '🇪🇸' },
        'pt-BR': { label: 'Português (Brasil)',flag: '🇧🇷' },
        fr:      { label: 'Français',          flag: '🇫🇷' },
        de:      { label: 'Deutsch',           flag: '🇩🇪' },
        ja:      { label: '日本語',            flag: '🇯🇵' },
    },
    _i18n: {
        en: {
            // Tabs
            'tab.dashboard': 'Home',
            'tab.dossier': 'Dossier',
            'tab.traffic': 'Traffic',
            'tab.dispatch': 'Dispatch',
            'tab.watchlist': 'Watchlist',
            'tab.settings': 'Settings',
            // Headers
            'header.dossier.title': 'Pilot Dossier',
            'header.dossier.sub': 'Comprehensive career analytics and high-level flight statistics.',
            'header.watchlist.title': 'Pilot Watchlist',
            'header.watchlist.sub': 'Track specific pilots in real-time.',
            'header.settings.title': 'Settings',
            'header.settings.sub': 'Manage your profile, preferences, and security.',
            'header.dispatch.title': 'Flight Dispatch',
            'header.traffic.title': 'Traffic',
            // Greetings
            'greet.morning': 'Good morning',
            'greet.afternoon': 'Good afternoon',
            'greet.evening': 'Good evening',
            // Common
            'common.save': 'Save changes',
            'common.cancel': 'Cancel',
            'common.delete': 'Delete',
            'common.close': 'Close',
            'common.loading': 'Loading…',
            'common.processing': 'Processing…',
            'common.none': 'None',
            'common.reset': 'Reset',
            // Stats
            'stat.grade': 'Pilot Level',
            'stat.xp': 'Total XP',
            'stat.flights': 'Flights Flown',
            // Empty states
            'empty.watchlist.title': 'No Pilots Tracked',
            'empty.watchlist.body': 'Add an Infinite Flight username above to start monitoring their live status.',
            'empty.dispatch': 'No upcoming flights filed.',
            'empty.recent': 'No recent flights found.',
            // Settings labels
            'set.appearance': 'Appearance',
            'set.theme': 'Theme',
            'set.density': 'Density',
            'set.theme.light': 'Light',
            'set.theme.dark': 'Dark',
            'set.density.cozy': 'Cozy',
            'set.density.compact': 'Compact',
            'set.profile': 'Profile details',
            'set.fullName': 'Full Name',
            'set.email': 'Email Address',
            'set.ifUsername': 'Infinite Flight Username',
            'set.timezone': 'Local Time Zone',
            'set.password': 'New Password (Optional)',
            'set.billing': 'Billing',
            'set.support': 'Support & Legal',
            'set.language': 'Language',
            'set.languageHelp': 'Affects core labels across the app. Synced across devices.',
            'set.accent': 'Accent color',
            'set.accentHelp': 'A subtle highlight color used for buttons, links, and active states.',
            'set.personality': 'Pilot identity',
            'set.bio': 'Tagline',
            'set.bioPlaceholder': 'e.g. Long-haul addict · 787 type rating · KJFK home base',
            'set.bioHelp': 'A short line shown on your Dossier. Up to 140 characters.',
            'set.cover': 'Cover image URL',
            'set.coverPlaceholder': 'https://…',
            'set.coverHelp': 'Optional banner image displayed on your Dossier.',
            'set.dockOrder': 'Tab order',
            'set.dockOrderHelp': 'Drag tabs in the dock to reorder them. Saved across devices.',
            // Drill-down
            'drill.title.grade': 'Pilot Grade Detail',
            'drill.title.xp': 'XP Breakdown',
            'drill.title.flights': 'Flights by Aircraft',
            'drill.title.icao': 'Airport',
            'drill.gotoTraffic': 'Open in Traffic',
            'drill.addToWatchlist': 'Add to Watchlist',
            // Trends
            'trend.title': 'Trends',
            'trend.sub': 'Comparing this period to the previous period — no flight records, just direction.',
            'trend.hoursMonth': 'Hours this month',
            'trend.flightsWeek': 'Flights this week',
            'trend.activeDays': 'Active days this week',
            'trend.fleetVariety': 'Aircraft types this month',
            'trend.vsLast': 'vs. previous',
            'trend.empty': 'Trends will appear once we have at least two periods of data.',
        },
        es: {
            'tab.dashboard': 'Inicio', 'tab.dossier': 'Dossier', 'tab.traffic': 'Tráfico',
            'tab.dispatch': 'Despacho', 'tab.watchlist': 'Seguimiento', 'tab.settings': 'Ajustes',
            'header.dossier.title': 'Dossier del Piloto',
            'header.dossier.sub': 'Análisis de carrera y estadísticas de vuelo completas.',
            'header.watchlist.title': 'Lista de Pilotos',
            'header.watchlist.sub': 'Sigue pilotos en tiempo real y recibe avisos cuando despeguen.',
            'header.settings.title': 'Ajustes', 'header.settings.sub': 'Gestiona tu perfil y preferencias.',
            'header.dispatch.title': 'Despacho de Vuelo', 'header.traffic.title': 'Tráfico',
            'greet.morning': 'Buenos días', 'greet.afternoon': 'Buenas tardes', 'greet.evening': 'Buenas noches',
            'common.save': 'Guardar cambios', 'common.cancel': 'Cancelar', 'common.delete': 'Eliminar',
            'common.close': 'Cerrar', 'common.loading': 'Cargando…', 'common.processing': 'Procesando…',
            'common.none': 'Ninguno', 'common.reset': 'Restablecer',
            'stat.grade': 'Nivel de Piloto', 'stat.xp': 'XP Total', 'stat.flights': 'Vuelos Realizados',
            'empty.watchlist.title': 'Sin Pilotos',
            'empty.watchlist.body': 'Añade un usuario de Infinite Flight para empezar.',
            'empty.dispatch': 'No hay vuelos programados.', 'empty.recent': 'No hay vuelos recientes.',
            'set.appearance': 'Apariencia', 'set.theme': 'Tema', 'set.density': 'Densidad',
            'set.theme.light': 'Claro', 'set.theme.dark': 'Oscuro',
            'set.density.cozy': 'Cómoda', 'set.density.compact': 'Compacta',
            'set.profile': 'Detalles del perfil', 'set.fullName': 'Nombre Completo',
            'set.email': 'Correo Electrónico', 'set.ifUsername': 'Usuario de Infinite Flight',
            'set.timezone': 'Zona Horaria', 'set.password': 'Nueva Contraseña (Opcional)',
            'set.billing': 'Facturación', 'set.support': 'Soporte y Legal',
            'set.language': 'Idioma', 'set.languageHelp': 'Afecta a las etiquetas principales. Se sincroniza entre dispositivos.',
            'set.accent': 'Color de acento', 'set.accentHelp': 'Color sutil usado en botones y enlaces.',
            'set.personality': 'Identidad de piloto', 'set.bio': 'Eslogan',
            'set.bioPlaceholder': 'p. ej. Vuelos largos · 787 · Base KJFK',
            'set.bioHelp': 'Una línea corta en tu Dossier. Hasta 140 caracteres.',
            'set.cover': 'URL de imagen de portada', 'set.coverPlaceholder': 'https://…',
            'set.coverHelp': 'Imagen opcional mostrada en tu Dossier.',
            'set.dockOrder': 'Orden de pestañas',
            'set.dockOrderHelp': 'Arrastra las pestañas para reordenarlas. Guardado entre dispositivos.',
            'drill.title.grade': 'Detalle de Grado', 'drill.title.xp': 'Desglose de XP',
            'drill.title.flights': 'Vuelos por Aeronave', 'drill.title.icao': 'Aeropuerto',
            'drill.gotoTraffic': 'Abrir en Tráfico', 'drill.addToWatchlist': 'Añadir a Lista',
            'trend.title': 'Tendencias',
            'trend.sub': 'Comparando este período con el anterior — solo dirección, sin historial.',
            'trend.hoursMonth': 'Horas este mes', 'trend.flightsWeek': 'Vuelos esta semana',
            'trend.activeDays': 'Días activos esta semana', 'trend.fleetVariety': 'Tipos de aeronave este mes',
            'trend.vsLast': 'vs. anterior',
            'trend.empty': 'Las tendencias aparecerán con al menos dos períodos de datos.',
        },
        'pt-BR': {
            'tab.dashboard': 'Início', 'tab.dossier': 'Dossiê', 'tab.traffic': 'Tráfego',
            'tab.dispatch': 'Despacho', 'tab.watchlist': 'Observação', 'tab.settings': 'Configurações',
            'header.dossier.title': 'Dossiê do Piloto',
            'header.dossier.sub': 'Análise de carreira e estatísticas de voo completas.',
            'header.watchlist.title': 'Lista de Pilotos',
            'header.watchlist.sub': 'Acompanhe pilotos em tempo real e seja notificado ao decolar.',
            'header.settings.title': 'Configurações', 'header.settings.sub': 'Gerencie seu perfil e preferências.',
            'header.dispatch.title': 'Despacho de Voo', 'header.traffic.title': 'Tráfego',
            'greet.morning': 'Bom dia', 'greet.afternoon': 'Boa tarde', 'greet.evening': 'Boa noite',
            'common.save': 'Salvar', 'common.cancel': 'Cancelar', 'common.delete': 'Excluir',
            'common.close': 'Fechar', 'common.loading': 'Carregando…', 'common.processing': 'Processando…',
            'common.none': 'Nenhum', 'common.reset': 'Redefinir',
            'stat.grade': 'Nível do Piloto', 'stat.xp': 'XP Total', 'stat.flights': 'Voos Realizados',
            'empty.watchlist.title': 'Sem Pilotos',
            'empty.watchlist.body': 'Adicione um usuário do Infinite Flight para começar.',
            'empty.dispatch': 'Nenhum voo programado.', 'empty.recent': 'Nenhum voo recente.',
            'set.appearance': 'Aparência', 'set.theme': 'Tema', 'set.density': 'Densidade',
            'set.theme.light': 'Claro', 'set.theme.dark': 'Escuro',
            'set.density.cozy': 'Confortável', 'set.density.compact': 'Compacta',
            'set.profile': 'Perfil', 'set.fullName': 'Nome Completo',
            'set.email': 'E-mail', 'set.ifUsername': 'Usuário Infinite Flight',
            'set.timezone': 'Fuso Horário', 'set.password': 'Nova Senha (Opcional)',
            'set.billing': 'Cobrança', 'set.support': 'Suporte e Legal',
            'set.language': 'Idioma', 'set.languageHelp': 'Afeta os rótulos principais. Sincronizado entre dispositivos.',
            'set.accent': 'Cor de destaque', 'set.accentHelp': 'Cor sutil usada em botões e links.',
            'set.personality': 'Identidade do piloto', 'set.bio': 'Slogan',
            'set.bioPlaceholder': 'ex. Long-haul · 787 · Base SBGR',
            'set.bioHelp': 'Linha curta no Dossiê. Até 140 caracteres.',
            'set.cover': 'URL da imagem de capa', 'set.coverPlaceholder': 'https://…',
            'set.coverHelp': 'Imagem opcional exibida no Dossiê.',
            'set.dockOrder': 'Ordem das abas',
            'set.dockOrderHelp': 'Arraste as abas para reordenar. Salvo entre dispositivos.',
            'drill.title.grade': 'Detalhe de Grade', 'drill.title.xp': 'Detalhamento de XP',
            'drill.title.flights': 'Voos por Aeronave', 'drill.title.icao': 'Aeroporto',
            'drill.gotoTraffic': 'Abrir em Tráfego', 'drill.addToWatchlist': 'Adicionar à Lista',
            'trend.title': 'Tendências',
            'trend.sub': 'Comparando este período ao anterior — só direção, sem histórico.',
            'trend.hoursMonth': 'Horas este mês', 'trend.flightsWeek': 'Voos esta semana',
            'trend.activeDays': 'Dias ativos esta semana', 'trend.fleetVariety': 'Tipos de aeronave este mês',
            'trend.vsLast': 'vs. anterior',
            'trend.empty': 'Tendências aparecerão com pelo menos dois períodos de dados.',
        },
        fr: {
            'tab.dashboard': 'Accueil', 'tab.dossier': 'Dossier', 'tab.traffic': 'Trafic',
            'tab.dispatch': 'Dispatch', 'tab.watchlist': 'Suivi', 'tab.settings': 'Paramètres',
            'header.dossier.title': 'Dossier Pilote',
            'header.dossier.sub': 'Analyses de carrière et statistiques de vol détaillées.',
            'header.watchlist.title': 'Suivi de Pilotes',
            'header.watchlist.sub': 'Suivez des pilotes en temps réel et soyez alerté au décollage.',
            'header.settings.title': 'Paramètres', 'header.settings.sub': 'Gérez votre profil et vos préférences.',
            'header.dispatch.title': 'Dispatch de Vol', 'header.traffic.title': 'Trafic',
            'greet.morning': 'Bonjour', 'greet.afternoon': 'Bon après-midi', 'greet.evening': 'Bonsoir',
            'common.save': 'Enregistrer', 'common.cancel': 'Annuler', 'common.delete': 'Supprimer',
            'common.close': 'Fermer', 'common.loading': 'Chargement…', 'common.processing': 'Traitement…',
            'common.none': 'Aucun', 'common.reset': 'Réinitialiser',
            'stat.grade': 'Niveau Pilote', 'stat.xp': 'XP Total', 'stat.flights': 'Vols Effectués',
            'empty.watchlist.title': 'Aucun Pilote Suivi',
            'empty.watchlist.body': 'Ajoutez un utilisateur Infinite Flight pour commencer.',
            'empty.dispatch': 'Aucun vol programmé.', 'empty.recent': 'Aucun vol récent.',
            'set.appearance': 'Apparence', 'set.theme': 'Thème', 'set.density': 'Densité',
            'set.theme.light': 'Clair', 'set.theme.dark': 'Sombre',
            'set.density.cozy': 'Confortable', 'set.density.compact': 'Compacte',
            'set.profile': 'Profil', 'set.fullName': 'Nom complet', 'set.email': 'Adresse e-mail',
            'set.ifUsername': "Nom d'utilisateur IF", 'set.timezone': 'Fuseau horaire',
            'set.password': 'Nouveau mot de passe (Optionnel)',
            'set.billing': 'Facturation', 'set.support': 'Support et Mentions',
            'set.language': 'Langue', 'set.languageHelp': 'Affecte les libellés principaux. Synchronisé entre appareils.',
            'set.accent': 'Couleur d\'accent', 'set.accentHelp': 'Couleur subtile pour boutons et liens.',
            'set.personality': 'Identité du pilote', 'set.bio': 'Slogan',
            'set.bioPlaceholder': 'ex. Long-courrier · 787 · Base LFPG',
            'set.bioHelp': 'Ligne courte sur votre Dossier. Jusqu\'à 140 caractères.',
            'set.cover': 'URL de l\'image de couverture', 'set.coverPlaceholder': 'https://…',
            'set.coverHelp': 'Image optionnelle affichée sur votre Dossier.',
            'set.dockOrder': 'Ordre des onglets',
            'set.dockOrderHelp': 'Glissez les onglets pour les réorganiser. Sauvé entre appareils.',
            'drill.title.grade': 'Détail du Grade', 'drill.title.xp': 'Détail XP',
            'drill.title.flights': 'Vols par Avion', 'drill.title.icao': 'Aéroport',
            'drill.gotoTraffic': 'Ouvrir dans Trafic', 'drill.addToWatchlist': 'Ajouter au Suivi',
            'trend.title': 'Tendances',
            'trend.sub': 'Période actuelle vs précédente — direction seulement, pas d\'historique.',
            'trend.hoursMonth': 'Heures ce mois-ci', 'trend.flightsWeek': 'Vols cette semaine',
            'trend.activeDays': 'Jours actifs cette semaine', 'trend.fleetVariety': 'Types d\'avions ce mois-ci',
            'trend.vsLast': 'vs. précédent',
            'trend.empty': 'Les tendances apparaîtront avec au moins deux périodes de données.',
        },
        de: {
            'tab.dashboard': 'Start', 'tab.dossier': 'Dossier', 'tab.traffic': 'Verkehr',
            'tab.dispatch': 'Dispatch', 'tab.watchlist': 'Beobachtung', 'tab.settings': 'Einstellungen',
            'header.dossier.title': 'Pilotendossier',
            'header.dossier.sub': 'Karriereanalysen und Flugstatistiken.',
            'header.watchlist.title': 'Pilotenliste',
            'header.watchlist.sub': 'Verfolge Piloten in Echtzeit und werde beim Start benachrichtigt.',
            'header.settings.title': 'Einstellungen', 'header.settings.sub': 'Profil und Einstellungen verwalten.',
            'header.dispatch.title': 'Flugdispatch', 'header.traffic.title': 'Verkehr',
            'greet.morning': 'Guten Morgen', 'greet.afternoon': 'Guten Tag', 'greet.evening': 'Guten Abend',
            'common.save': 'Speichern', 'common.cancel': 'Abbrechen', 'common.delete': 'Löschen',
            'common.close': 'Schließen', 'common.loading': 'Lade…', 'common.processing': 'Verarbeite…',
            'common.none': 'Keine', 'common.reset': 'Zurücksetzen',
            'stat.grade': 'Pilotenstufe', 'stat.xp': 'Gesamt-XP', 'stat.flights': 'Flüge',
            'empty.watchlist.title': 'Keine Piloten',
            'empty.watchlist.body': 'Füge einen Infinite Flight-Namen hinzu, um zu starten.',
            'empty.dispatch': 'Keine geplanten Flüge.', 'empty.recent': 'Keine neuen Flüge.',
            'set.appearance': 'Erscheinungsbild', 'set.theme': 'Thema', 'set.density': 'Dichte',
            'set.theme.light': 'Hell', 'set.theme.dark': 'Dunkel',
            'set.density.cozy': 'Gemütlich', 'set.density.compact': 'Kompakt',
            'set.profile': 'Profil', 'set.fullName': 'Vollständiger Name', 'set.email': 'E-Mail',
            'set.ifUsername': 'IF-Benutzername', 'set.timezone': 'Zeitzone',
            'set.password': 'Neues Passwort (Optional)',
            'set.billing': 'Abrechnung', 'set.support': 'Support & Rechtliches',
            'set.language': 'Sprache', 'set.languageHelp': 'Betrifft Hauptbezeichnungen. Geräteübergreifend synchronisiert.',
            'set.accent': 'Akzentfarbe', 'set.accentHelp': 'Subtile Farbe für Buttons und Links.',
            'set.personality': 'Pilotenidentität', 'set.bio': 'Slogan',
            'set.bioPlaceholder': 'z. B. Langstrecke · 787 · Heimat EDDF',
            'set.bioHelp': 'Kurze Zeile im Dossier. Bis zu 140 Zeichen.',
            'set.cover': 'Cover-Bild URL', 'set.coverPlaceholder': 'https://…',
            'set.coverHelp': 'Optionales Bild im Dossier.',
            'set.dockOrder': 'Tab-Reihenfolge',
            'set.dockOrderHelp': 'Tabs zum Sortieren ziehen. Geräteübergreifend gespeichert.',
            'drill.title.grade': 'Grade-Details', 'drill.title.xp': 'XP-Aufschlüsselung',
            'drill.title.flights': 'Flüge nach Flugzeug', 'drill.title.icao': 'Flughafen',
            'drill.gotoTraffic': 'In Verkehr öffnen', 'drill.addToWatchlist': 'Zur Liste hinzufügen',
            'trend.title': 'Trends',
            'trend.sub': 'Vergleich zur Vorperiode — nur Richtung, keine Historie.',
            'trend.hoursMonth': 'Stunden diesen Monat', 'trend.flightsWeek': 'Flüge diese Woche',
            'trend.activeDays': 'Aktive Tage', 'trend.fleetVariety': 'Flugzeugtypen',
            'trend.vsLast': 'vs. zuvor',
            'trend.empty': 'Trends erscheinen mit mindestens zwei Datenperioden.',
        },
        ja: {
            'tab.dashboard': 'ホーム', 'tab.dossier': 'ドシエ', 'tab.traffic': '交通',
            'tab.dispatch': 'ディスパッチ', 'tab.watchlist': 'ウォッチリスト', 'tab.settings': '設定',
            'header.dossier.title': 'パイロット・ドシエ',
            'header.dossier.sub': 'キャリア分析と詳細な飛行統計。',
            'header.watchlist.title': 'パイロット・ウォッチリスト',
            'header.watchlist.sub': 'リアルタイムでパイロットを追跡し、離陸時に通知を受け取ります。',
            'header.settings.title': '設定', 'header.settings.sub': 'プロファイルと設定を管理します。',
            'header.dispatch.title': 'フライト・ディスパッチ', 'header.traffic.title': '交通',
            'greet.morning': 'おはようございます', 'greet.afternoon': 'こんにちは', 'greet.evening': 'こんばんは',
            'common.save': '変更を保存', 'common.cancel': 'キャンセル', 'common.delete': '削除',
            'common.close': '閉じる', 'common.loading': '読込中…', 'common.processing': '処理中…',
            'common.none': 'なし', 'common.reset': 'リセット',
            'stat.grade': 'パイロット・レベル', 'stat.xp': '総XP', 'stat.flights': '飛行回数',
            'empty.watchlist.title': 'パイロット未追跡',
            'empty.watchlist.body': 'Infinite Flightのユーザー名を追加して開始します。',
            'empty.dispatch': '予定されている飛行はありません。', 'empty.recent': '最近の飛行はありません。',
            'set.appearance': '外観', 'set.theme': 'テーマ', 'set.density': '密度',
            'set.theme.light': 'ライト', 'set.theme.dark': 'ダーク',
            'set.density.cozy': 'ゆとり', 'set.density.compact': 'コンパクト',
            'set.profile': 'プロフィール', 'set.fullName': '氏名', 'set.email': 'メールアドレス',
            'set.ifUsername': 'IFユーザー名', 'set.timezone': 'タイムゾーン',
            'set.password': '新しいパスワード(任意)',
            'set.billing': '請求', 'set.support': 'サポートと法的情報',
            'set.language': '言語', 'set.languageHelp': '主なラベルに反映されます。デバイス間で同期。',
            'set.accent': 'アクセントカラー', 'set.accentHelp': 'ボタンやリンクに使う控えめな色。',
            'set.personality': 'パイロットの個性', 'set.bio': 'スローガン',
            'set.bioPlaceholder': '例: 長距離専門・787・RJTT拠点',
            'set.bioHelp': 'ドシエに表示される短い一行。140文字まで。',
            'set.cover': 'カバー画像URL', 'set.coverPlaceholder': 'https://…',
            'set.coverHelp': 'ドシエに表示される任意の画像。',
            'set.dockOrder': 'タブの順序',
            'set.dockOrderHelp': 'ドラッグして並び替え。デバイス間で保存。',
            'drill.title.grade': 'グレード詳細', 'drill.title.xp': 'XP内訳',
            'drill.title.flights': '機種別フライト', 'drill.title.icao': '空港',
            'drill.gotoTraffic': '交通で開く', 'drill.addToWatchlist': 'ウォッチに追加',
            'trend.title': 'トレンド',
            'trend.sub': '前期間との比較 — 方向のみ、履歴なし。',
            'trend.hoursMonth': '今月の時間', 'trend.flightsWeek': '今週のフライト',
            'trend.activeDays': '今週の活動日', 'trend.fleetVariety': '今月の機種',
            'trend.vsLast': '前期間比',
            'trend.empty': '2期間分のデータが揃うとトレンドが表示されます。',
        },
    },

/** Translate a key. Falls back to English, then to the key itself. */
    t(key, fallback) {
        const dict = this._i18n[this._locale];
        if (dict && dict[key] != null) return dict[key];
        const en = this._i18n.en;
        if (en && en[key] != null) return en[key];
        return fallback != null ? fallback : key;
    },

    /** Resolves a human-readable aircraft name from API UUIDs */
    _resolveAircraftName(aircraftId, liveryId) {
        if (!aircraftId) return 'Unknown Airframe';
        const aId = String(aircraftId).toLowerCase();
        const lId = liveryId ? String(liveryId).toLowerCase() : null;
        
        if (lId && this._liveryMap.has(lId)) {
            const lData = this._liveryMap.get(lId);
            if (lData.aircraftName) return lData.aircraftName;
        }
        if (this._aircraftMap.has(aId)) {
            return this._aircraftMap.get(aId);
        }
        return 'Unknown Airframe';
    },

    // Map legacy theme names → new palette keys (so old saved values still work)
    _normalizeTheme(name) {
        if (name === 'white' || name === 'light-gray') return 'light';
        if (name === 'dark-gray' || name === 'dark') return 'dark';
        return name === 'light' || name === 'dark' ? name : 'light';
    },

init(supabaseClient) {
        this._supabase = supabaseClient;
        FlightDispatchService.init(supabaseClient);
        FlightDispatchUI.init();

        this._supabase.auth.onAuthStateChange((event, session) => {
            if (session?.user) {
                this._currentUser = session.user;
                if (session.user.user_metadata?.timezone) {
                    this._timezone = session.user.user_metadata.timezone;
                }

                // --- PREMIUM PLANE COLOR BOOTSTRAP ---
                // Trigger an immediate map re-tag now that we know who the
                // logged-in pilot is (their own plane should turn gold).
                if (typeof window !== 'undefined' && typeof window.refreshPilotRelations === 'function') {
                    window.refreshPilotRelations();
                }

                // Fetch the watchlist eagerly on auth resolve, not only when
                // the profile overlay is opened — otherwise watchlist colors
                // won't appear on the map until the user manually opens
                // their profile.
                this._fetchWatchlist().then(() => {
                    if (typeof window !== 'undefined' && typeof window.refreshPilotRelations === 'function') {
                        window.refreshPilotRelations();
                    }
                }).catch(() => { /* already logged inside _fetchWatchlist */ });
            } else {
                this._currentUser = null;
                this._watchlist = [];
                if (typeof window !== 'undefined' && typeof window.refreshPilotRelations === 'function') {
                    window.refreshPilotRelations();
                }
            }

            if (event === 'USER_UPDATED' && session?.user) {
                if (session.user.user_metadata?.theme) {
                    this.setTheme(this._normalizeTheme(session.user.user_metadata.theme), false);
                }
                if (session.user.user_metadata?.density) {
                    this.setDensity(session.user.user_metadata.density, false);
                }
                if (session.user.user_metadata?.timezone) {
                    this._timezone = session.user.user_metadata.timezone;
                }

                if (this._isOpen) {
                    const ifUsername = session.user.user_metadata?.if_username;
                    if (ifUsername) this._fetchInfiniteFlightData(ifUsername);
                    this._render();
                }
            }
        });

        if (!this._socketUnsubscribe) {
            this._socketUnsubscribe = socketDataHub.subscribe('all_flights_update', (payload) => {
                if (!payload || !payload.flights) return;
                
                this._currentAllFlights = payload.flights;

                const ifUsername = this._currentUser?.user_metadata?.if_username;

                if (ifUsername) {
                    const myFlights = payload.flights.filter(f => f.username?.toLowerCase() === ifUsername.toLowerCase());
                    const previouslyHadFlights = this._liveFlights.length > 0;
                    this._liveFlights = myFlights;
                    if (this._isOpen && this._activeTab === 'dashboard') {
                        if (this._liveFlights.length > 0 || previouslyHadFlights) {
                            this._updateLiveFlightDOM();
                        }
                    }
                }

                if (this._watchlist.length > 0) {
                    this._prevWatchedStatus = { ...this._watchedPilotStatus };
                    const newStatus = {};
                    for (const entry of this._watchlist) {
                        const un = entry.watched_username.toLowerCase();
                        const flight = payload.flights.find(f => f.username?.toLowerCase() === un);
                        newStatus[un] = { isLive: !!flight, flight: flight || null };
                    }
                    this._watchedPilotStatus = newStatus;

                    if (this._userPrefs.notification_watchlist_enabled) {
                        for (const [un, cur] of Object.entries(newStatus)) {
                            const prev = this._prevWatchedStatus[un];
                            if (cur.isLive && prev && !prev.isLive) {
                                const f = cur.flight;
                                const route = (f?.departureIcao && f?.arrivalIcao)
                                    ? ` on ${f.departureIcao} → ${f.arrivalIcao}`
                                    : '';
                                this._showToast(`<i class="fa-solid fa-plane-departure" style="margin-right:8px;"></i><strong>${f?.username || un}</strong> is now airborne${route}`, 'info');
                            }
                        }
                    }

                    if (this._isOpen && this._activeTab === 'watchlist') {
                        this._updateWatchlistDOM();
                    }
                }
            });
        }
    },

    open(user) {
        // Mobile redirect
        if (window.innerWidth <= 768) {
            if (MobileDashboardUI && typeof MobileDashboardUI.open === 'function') {
                MobileDashboardUI.open(user);
                return;
            }
        }

        this._currentUser = user;

        if (user?.user_metadata?.timezone) {
            this._timezone = user.user_metadata.timezone;
        }

        // Onboarding intercept
        const needsOnboarding = !user?.user_metadata?.onboarding_complete;
        this._activeTab = needsOnboarding ? 'onboarding' : 'dashboard';

        // Restore theme + density (with legacy theme name normalization)
        const rawTheme = user?.user_metadata?.theme || localStorage.getItem('pui-theme') || 'light';
        this.setTheme(this._normalizeTheme(rawTheme), false);

        const rawDensity = user?.user_metadata?.density || localStorage.getItem('pui-density') || 'cozy';
        this.setDensity(rawDensity === 'compact' ? 'compact' : 'cozy', false);

        // Restore personalization + locale
        const rawLocale = user?.user_metadata?.locale || localStorage.getItem('pui-locale') || 'en';
        this._locale = this._LOCALES[rawLocale] ? rawLocale : 'en';

        const rawAccent = user?.user_metadata?.accent_color || localStorage.getItem('pui-accent') || 'caramel';
        this._accent = this._ACCENT_PRESETS[rawAccent] ? rawAccent : 'caramel';

        this._bio       = user?.user_metadata?.pilot_bio || '';
        this._coverUrl  = user?.user_metadata?.cover_url || '';
        this._dockOrder = Array.isArray(user?.user_metadata?.dock_order) ? user.user_metadata.dock_order : null;

        if (!this._injected) {
            this._inject();
            this._injected = true;
        }

        if (!this._airspaceNetwork) {
            this._airspaceNetwork = new PredictiveAirspaceNetwork();
            this._airspaceNetwork.bindTelemetryStream();
            this._airspaceNetwork.setActiveNodes(['KJFK', 'EGLL', 'KLAX', 'OMDB']);
        }

        const overlay = document.getElementById('profile-overlay');
        if (overlay) {
            overlay.setAttribute('data-theme', this._theme);
            overlay.setAttribute('data-density', this._density);
        }
        // Apply accent CSS variable overrides on top of the theme palette
        this._applyAccent();

        // Force a fresh shell on each open so onboarding state is respected
        this._shellBuilt = false;
        this._editingFlightId = null; // Reset edit state
        this._render();
        this._fetchSubscriptionData();
        this._fetchFlightPlans();
        this._fetchWatchlist();
        this._fetchUserPreferences();

        const ifUsername = user?.user_metadata?.if_username;
        if (ifUsername) {
            this._fetchInfiniteFlightData(ifUsername);
        }

        requestAnimationFrame(() => {
            requestAnimationFrame(() => {
                document.getElementById('profile-overlay')?.classList.add('pui-open');
                this._isOpen = true;
                document.body.style.overflow = 'hidden';
            });
        });
    },

    close() {
        document.getElementById('profile-overlay')?.classList.remove('pui-open');
        this._isOpen = false;
        document.body.style.overflow = '';
        this._editingFlightId = null;

        if (this._airspaceRefreshTimer) {
            clearInterval(this._airspaceRefreshTimer);
            this._airspaceRefreshTimer = null;
        }

        setTimeout(() => {
            if (this._currentUser?.user_metadata?.onboarding_complete) {
                this._activeTab = 'dashboard';
            }
        }, 300);
    },

    /**
     * Fast tab switch: only refreshes the content area + dock active state.
     * Avoids the full-shell innerHTML re-render that caused most of the lag.
     */
    switchTab(tabId) {
        if (this._activeTab === tabId) return;

        const fromOnboarding = this._activeTab === 'onboarding';
        const toOnboarding = tabId === 'onboarding';

        this._activeTab = tabId;
        
        // Reset specific states upon navigation
        if (tabId !== 'flight-plan') {
            this._editingFlightId = null;
        }

        // If we're crossing the onboarding boundary, the chrome (dock visibility)
        // changes — fall back to a full render. Otherwise, only swap content.
        if (fromOnboarding || toOnboarding) {
            this._render();
        } else {
            this._renderContentOnly();
            this._syncDockActiveState();
        }

        if (this._airspaceRefreshTimer) {
            clearInterval(this._airspaceRefreshTimer);
            this._airspaceRefreshTimer = null;
        }

        if (this._activeTab === 'airspace-intel') {
            this._airspaceRefreshTimer = setInterval(() => {
                if (this._isOpen && this._activeTab === 'airspace-intel') {
                    this._updateAirspaceDOM();
                }
            }, 8000);
        }
    },

    setTheme(themeName, saveToLocal = true) {
        const t = this._normalizeTheme(themeName);
        this._theme = t;
        if (saveToLocal) {
            localStorage.setItem('pui-theme', t);
        }
        const overlay = document.getElementById('profile-overlay');
        if (overlay) overlay.setAttribute('data-theme', t);

        // Accent variant depends on theme — re-apply so colors stay consistent.
        this._applyAccent();

        // SYNC THEME EXTERNALLY (landingUI is now listening for this event)
        window.dispatchEvent(new CustomEvent('puiThemeChanged', { detail: { theme: t } }));
    },

    setDensity(density, saveToLocal = true) {
        const d = density === 'compact' ? 'compact' : 'cozy';
        this._density = d;
        if (saveToLocal) {
            localStorage.setItem('pui-density', d);
        }
        const overlay = document.getElementById('profile-overlay');
        if (overlay) overlay.setAttribute('data-density', d);
    },

    /** Cycle: light ↔ dark */
    cycleTheme() {
        const next = this._theme === 'light' ? 'dark' : 'light';
        this.setTheme(next, true);
        // Persist to user metadata (silent, best-effort)
        this._supabase?.auth.updateUser({ data: { theme: next } }).catch(() => {});
    },

    /** Cycle: cozy ↔ compact */
    cycleDensity() {
        const next = this._density === 'cozy' ? 'compact' : 'cozy';
        this.setDensity(next, true);
        this._supabase?.auth.updateUser({ data: { density: next } }).catch(() => {});
    },

    /**
     * Re-render the accent swatch colors in the Settings panel — used when
     * the theme changes, since each preset has separate light/dark variants
     * and the swatch should preview the variant the user will actually see.
     */
    _refreshAccentSwatches() {
        document.querySelectorAll('.pui-accent-swatch').forEach(btn => {
            const key = btn.dataset.accent;
            const preset = this._ACCENT_PRESETS[key];
            if (!preset) return;
            const variant = this._theme === 'dark' ? preset.dark : preset.light;
            btn.style.background = variant.c;
            btn.classList.toggle('active', key === this._accent);
            btn.innerHTML = key === this._accent ? '<i class="fa-solid fa-check"></i>' : '';
        });
    },

    // ═══════════════════════════════════════════════════════════════════════
    // PERSONALIZATION — accent color, locale, dock order
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Apply an accent preset to the live overlay by overriding the four
     * --pui-accent* CSS variables. Called whenever theme or accent changes,
     * since the chosen variant depends on the active theme.
     */
    _applyAccent() {
        const overlay = document.getElementById('profile-overlay');
        if (!overlay) return;
        const preset = this._ACCENT_PRESETS[this._accent] || this._ACCENT_PRESETS.caramel;
        const variant = this._theme === 'dark' ? preset.dark : preset.light;
        overlay.style.setProperty('--pui-accent', variant.c);
        overlay.style.setProperty('--pui-accent-hover', variant.h);
        overlay.style.setProperty('--pui-accent-soft', variant.s);
        overlay.style.setProperty('--pui-accent-glow', variant.g);
    },

    /** Set accent color preset (key into _ACCENT_PRESETS). */
    setAccent(accentKey, persist = true) {
        if (!this._ACCENT_PRESETS[accentKey]) accentKey = 'caramel';
        this._accent = accentKey;
        this._applyAccent();
        if (persist) {
            localStorage.setItem('pui-accent', accentKey);
            this._supabase?.auth.updateUser({ data: { accent_color: accentKey } }).catch(() => {});
        }
    },

    /** Set the active locale and re-render so all t() calls pick it up. */
    setLocale(locale, persist = true) {
        if (!this._LOCALES[locale]) locale = 'en';
        const changed = this._locale !== locale;
        this._locale = locale;
        if (persist) {
            localStorage.setItem('pui-locale', locale);
            this._supabase?.auth.updateUser({ data: { locale } }).catch(() => {});
        }
        if (changed && this._isOpen) {
            // Full re-render so dock labels, headers, and content all refresh.
            this._shellBuilt = false;
            this._render();
        }
    },

    /** Save pilot bio to user_metadata. Stored in this._bio for fast access. */
    async setBio(bio) {
        const trimmed = (bio || '').slice(0, 140);
        this._bio = trimmed;
        try {
            await this._supabase?.auth.updateUser({ data: { pilot_bio: trimmed } });
        } catch (err) {
            console.warn('[ProfileUI] Failed to save bio:', err.message);
        }
    },

    /** Save cover banner image URL. Caller validates the URL shape upstream. */
    async setCoverUrl(url) {
        const trimmed = (url || '').trim().slice(0, 500);
        this._coverUrl = trimmed;
        try {
            await this._supabase?.auth.updateUser({ data: { cover_url: trimmed } });
        } catch (err) {
            console.warn('[ProfileUI] Failed to save cover_url:', err.message);
        }
    },

    /**
     * Resolve the effective dock order — merges saved order with the default,
     * dropping unknown ids and appending any new defaults that the user hasn't
     * seen yet. Always returns the full set of valid tab ids.
     */
    _resolveDockOrder() {
        const valid = new Set(this._DEFAULT_DOCK_ORDER);
        const saved = Array.isArray(this._dockOrder) ? this._dockOrder.filter(id => valid.has(id)) : [];
        const seen  = new Set(saved);
        const tail  = this._DEFAULT_DOCK_ORDER.filter(id => !seen.has(id));
        return saved.length ? [...saved, ...tail] : [...this._DEFAULT_DOCK_ORDER];
    },

    /** Persist the current dock order to user_metadata. */
    async setDockOrder(order) {
        const valid = new Set(this._DEFAULT_DOCK_ORDER);
        const cleaned = (order || []).filter(id => valid.has(id));
        this._dockOrder = cleaned.length ? cleaned : null;
        try {
            await this._supabase?.auth.updateUser({ data: { dock_order: this._dockOrder } });
        } catch (err) {
            console.warn('[ProfileUI] Failed to save dock_order:', err.message);
        }
    },

    /** Reset dock to default order. */
    async resetDockOrder() {
        this._dockOrder = null;
        try {
            await this._supabase?.auth.updateUser({ data: { dock_order: null } });
        } catch (err) {
            console.warn('[ProfileUI] Failed to reset dock_order:', err.message);
        }
        // Re-render dock area in place
        const dock = document.querySelector('.pui-dock');
        if (dock) {
            const tmp = document.createElement('div');
            tmp.innerHTML = this._getDockHTML();
            dock.replaceWith(tmp.firstElementChild);
            this._wireDockListeners();
        }
    },

    // ═══════════════════════════════════════════════════════════════════════
    // COMPARATIVE STATS — period-vs-period deltas (no flight history surface)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Compute "this period vs previous period" deltas from the IF logbook.
     * Returns null when we don't have enough data (need at least one prior
     * period to compare against). Crucially, this surface does NOT expose any
     * individual flight records — only aggregate directional change.
     */
    _computeComparativeStats() {
        const logbook = this._ifData?.logbook;
        if (!Array.isArray(logbook) || logbook.length === 0) return null;

        const now = new Date();
        const ms = (d) => d.getTime();

        const startOfThisMonth = new Date(now.getFullYear(), now.getMonth(), 1);
        const startOfLastMonth = new Date(now.getFullYear(), now.getMonth() - 1, 1);

        const sevenDaysAgo  = new Date(ms(now) - 7  * 86400000);
        const fourteenDaysAgo = new Date(ms(now) - 14 * 86400000);

        let hoursThisMonth = 0, hoursLastMonth = 0;
        let flightsThisWeek = 0, flightsLastWeek = 0;
        const acftThisMonth = new Set(), acftLastMonth = new Set();
        const daysThisWeek  = new Set(), daysLastWeek  = new Set();

        for (const f of logbook) {
            if (!f?.created) continue;
            const d  = new Date(f.created);
            const dT = ms(d);
            const minutes = typeof f.totalTime === 'number' ? f.totalTime : 0;

            if (dT >= ms(startOfThisMonth)) {
                hoursThisMonth += minutes / 60;
                if (f.aircraftId) acftThisMonth.add(f.aircraftId);
            } else if (dT >= ms(startOfLastMonth) && dT < ms(startOfThisMonth)) {
                hoursLastMonth += minutes / 60;
                if (f.aircraftId) acftLastMonth.add(f.aircraftId);
            }

            if (dT >= ms(sevenDaysAgo)) {
                flightsThisWeek += 1;
                daysThisWeek.add(d.toISOString().slice(0, 10));
            } else if (dT >= ms(fourteenDaysAgo) && dT < ms(sevenDaysAgo)) {
                flightsLastWeek += 1;
                daysLastWeek.add(d.toISOString().slice(0, 10));
            }
        }

        const anyData = hoursThisMonth || hoursLastMonth || flightsThisWeek || flightsLastWeek
                     || acftThisMonth.size || acftLastMonth.size || daysThisWeek.size || daysLastWeek.size;
        if (!anyData) return null;

        const buildDelta = (current, previous) => {
            const diff = current - previous;
            let pct = null;
            if (previous > 0) {
                pct = Math.round((diff / previous) * 100);
            } else if (current > 0) {
                pct = 100;
            }
            return { current, previous, diff, pct };
        };

        return {
            hoursMonth:   buildDelta(+hoursThisMonth.toFixed(1), +hoursLastMonth.toFixed(1)),
            flightsWeek:  buildDelta(flightsThisWeek, flightsLastWeek),
            activeDays:   buildDelta(daysThisWeek.size, daysLastWeek.size),
            fleetVariety: buildDelta(acftThisMonth.size, acftLastMonth.size),
        };
    },

    /**
     * Render the Trends card for the Dossier tab. Pure function of _ifData.
     * Returns a non-empty card always — uses an empty-state when not enough data.
     */
    _getTrendsCardHTML() {
        const stats = this._computeComparativeStats();
        if (!stats) {
            return `
                <div class="pui-card">
                    <div class="pui-card-header"><h3><i class="fa-solid fa-chart-line" style="color: var(--pui-accent); margin-right:8px;"></i>${this.t('trend.title')}</h3></div>
                    <div class="pui-card-body">
                        <div class="pui-empty-inline">${this.t('trend.empty')}</div>
                    </div>
                </div>`;
        }

        const fmtDelta = (d) => {
            if (d.pct == null) return `<span class="pui-trend-neutral">—</span>`;
            const arrow = d.diff > 0 ? '▲' : d.diff < 0 ? '▼' : '●';
            const cls   = d.diff > 0 ? 'pui-trend-up' : d.diff < 0 ? 'pui-trend-down' : 'pui-trend-neutral';
            const sign  = d.pct > 0 ? '+' : '';
            return `<span class="${cls}"><span class="pui-trend-arrow">${arrow}</span>${sign}${d.pct}%</span>`;
        };

        const row = (labelKey, d, fmtCurrent) => `
            <div class="pui-trend-row">
                <div class="pui-trend-label">${this.t(labelKey)}</div>
                <div class="pui-trend-current">${fmtCurrent(d.current)}</div>
                <div class="pui-trend-delta">${fmtDelta(d)}</div>
                <div class="pui-trend-prev">${this.t('trend.vsLast')} ${fmtCurrent(d.previous)}</div>
            </div>`;

        return `
            <div class="pui-card">
                <div class="pui-card-header pui-card-header-row">
                    <h3><i class="fa-solid fa-chart-line" style="color: var(--pui-accent); margin-right:8px;"></i>${this.t('trend.title')}</h3>
                    <span class="pui-mono-meta-sm">${this.t('trend.sub')}</span>
                </div>
                <div class="pui-card-body">
                    <div class="pui-trends-grid">
                        ${row('trend.hoursMonth',   stats.hoursMonth,   v => `${v}h`)}
                        ${row('trend.flightsWeek',  stats.flightsWeek,  v => `${v}`)}
                        ${row('trend.activeDays',   stats.activeDays,   v => `${v}`)}
                        ${row('trend.fleetVariety', stats.fleetVariety, v => `${v}`)}
                    </div>
                </div>
            </div>`;
    },

    // ═══════════════════════════════════════════════════════════════════════
    // DRILL-DOWN — generic detail modal triggered by data-drill attributes
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Show a detail modal for a stat or entity. type = 'grade' | 'xp' |
     * 'flights' | 'icao' | 'callsign'. payload carries any context.
     */
    _showDrillDown(type, payload = {}) {
        const existing = document.getElementById('pui-drill-modal');
        if (existing) existing.remove();

        const overlay = document.createElement('div');
        overlay.id = 'pui-drill-modal';
        overlay.className = 'pui-wrapper-layer';
        overlay.setAttribute('data-theme', this._theme);
        overlay.setAttribute('data-density', this._density);
        overlay.style.zIndex = '10001';

        // Inherit accent overrides on the modal layer too
        const preset = this._ACCENT_PRESETS[this._accent] || this._ACCENT_PRESETS.caramel;
        const variant = this._theme === 'dark' ? preset.dark : preset.light;
        overlay.style.setProperty('--pui-accent', variant.c);
        overlay.style.setProperty('--pui-accent-hover', variant.h);
        overlay.style.setProperty('--pui-accent-soft', variant.s);
        overlay.style.setProperty('--pui-accent-glow', variant.g);

        const body = this._getDrillDownBody(type, payload);

        overlay.innerHTML = `
            <div class="pui-drill-box pui-fade-in">
                <div class="pui-drill-header">
                    <h3>${body.title}</h3>
                    <button class="pui-icon-btn" id="pui-drill-close" title="${this.t('common.close')}">
                        <i class="fa-solid fa-xmark"></i>
                    </button>
                </div>
                <div class="pui-drill-body">${body.html}</div>
                ${body.actions ? `<div class="pui-drill-actions">${body.actions}</div>` : ''}
            </div>
        `;

        document.body.appendChild(overlay);
        requestAnimationFrame(() => requestAnimationFrame(() => overlay.classList.add('pui-open')));

        const cleanup = () => {
            overlay.classList.remove('pui-open');
            setTimeout(() => overlay.remove(), 240);
            document.removeEventListener('keydown', escHandler);
        };
        const escHandler = (e) => { if (e.key === 'Escape') cleanup(); };
        document.addEventListener('keydown', escHandler);

        document.getElementById('pui-drill-close')?.addEventListener('click', cleanup);
        overlay.addEventListener('click', (e) => { if (e.target === overlay) cleanup(); });

        document.getElementById('pui-drill-goto-traffic')?.addEventListener('click', () => {
            cleanup();
            if (payload.icao) {
                window.dispatchEvent(new CustomEvent('puiFocusHub', { detail: { icao: payload.icao } }));
            }
            this.switchTab('airspace-intel');
        });
        document.getElementById('pui-drill-watch-pilot')?.addEventListener('click', () => {
            cleanup();
            this.switchTab('watchlist');
            setTimeout(() => {
                const input = document.getElementById('pui-watchlist-input');
                if (input && payload.callsign) {
                    input.value = payload.callsign;
                    input.focus();
                }
            }, 120);
        });
    },

    /**
     * Build the title + body HTML + (optional) action buttons for a given
     * drill-down type. Returns { title, html, actions }.
     */
    _getDrillDownBody(type, payload) {
        const stats = this._ifData?.stats;
        const logbook = this._ifData?.logbook || [];

        if (type === 'grade') {
            const grade      = stats?.gradeDetails?.gradeIndex ?? '—';
            const violations = stats?.violations ?? '—';
            const landings   = stats?.landingCount ?? '—';
            const onlineHrs  = stats?.onlineFlightTime ? (stats.onlineFlightTime / 60).toFixed(1) + 'h' : '—';
            return {
                title: this.t('drill.title.grade'),
                html: `
                    <div class="pui-drill-stat-row"><span>Current grade</span><strong>${grade}</strong></div>
                    <div class="pui-drill-stat-row"><span>Online flight time</span><strong>${onlineHrs}</strong></div>
                    <div class="pui-drill-stat-row"><span>Landing count</span><strong>${typeof landings === 'number' ? landings.toLocaleString() : landings}</strong></div>
                    <div class="pui-drill-stat-row"><span>Violations</span><strong>${violations}</strong></div>
                    <p class="pui-drill-note">Grade requirements update at the start of each Infinite Flight rolling period.</p>
                `,
            };
        }

        if (type === 'xp') {
            const xp = stats?.totalXP ?? 0;
            const total = logbook.length;
            const totalMins = logbook.reduce((s, f) => s + (f.totalTime || 0), 0);
            const totalHours = (totalMins / 60).toFixed(1);
            const xpPerFlight = total > 0 ? Math.round(xp / total) : 0;
            const xpPerHour   = totalMins > 0 ? Math.round(xp / (totalMins / 60)) : 0;
            return {
                title: this.t('drill.title.xp'),
                html: `
                    <div class="pui-drill-stat-row"><span>Total XP</span><strong>${xp.toLocaleString()}</strong></div>
                    <div class="pui-drill-stat-row"><span>Across</span><strong>${total.toLocaleString()} flights · ${totalHours}h</strong></div>
                    <div class="pui-drill-stat-row"><span>Avg XP / flight</span><strong>${xpPerFlight.toLocaleString()}</strong></div>
                    <div class="pui-drill-stat-row"><span>Avg XP / hour</span><strong>${xpPerHour.toLocaleString()}</strong></div>
                `,
            };
        }

if (type === 'flights') {
            const byAcft = {};
            for (const f of logbook) {
                const aId = f.aircraftId || f.aircraftID;
                const lId = f.liveryId || f.liveryID;
                if (!aId) continue;
                
                const name = this._resolveAircraftName(aId, lId);
                if (!byAcft[name]) byAcft[name] = { count: 0, minutes: 0 };
                byAcft[name].count   += 1;
                byAcft[name].minutes += (f.totalTime || 0);
            }
            const rows = Object.entries(byAcft)
                .sort((a, b) => b[1].count - a[1].count)
                .slice(0, 8);

            const totalCount = logbook.length || 1;
            const html = rows.length
                ? rows.map(([id, agg]) => {
                    const pct = Math.round((agg.count / totalCount) * 100);
                    const hrs = (agg.minutes / 60).toFixed(1);
                    return `
                        <div class="pui-drill-bar-row">
                            <div class="pui-drill-bar-label">
                                <span class="pui-drill-bar-name">${id}</span>
                                <span class="pui-drill-bar-meta">${agg.count} · ${hrs}h</span>
                            </div>
                            <div class="pui-drill-bar-track">
                                <div class="pui-drill-bar-fill" style="width:${pct}%"></div>
                            </div>
                        </div>`;
                }).join('')
                : `<div class="pui-empty-inline">${this.t('common.none')}</div>`;

            return { title: this.t('drill.title.flights'), html };
        }

        if (type === 'icao') {
            const icao = (payload.icao || '').toUpperCase();
            const flights = this._currentAllFlights || [];
            const inbound  = flights.filter(f => (f.arrivalIcao   || '').toUpperCase() === icao).length;
            const outbound = flights.filter(f => (f.departureIcao || '').toUpperCase() === icao).length;
            return {
                title: `${this.t('drill.title.icao')} · ${icao}`,
                html: `
                    <div class="pui-drill-stat-row"><span>Live inbound</span><strong>${inbound}</strong></div>
                    <div class="pui-drill-stat-row"><span>Live outbound</span><strong>${outbound}</strong></div>
                `,
                actions: `
                    <button class="pui-btn-primary" id="pui-drill-goto-traffic">
                        <i class="fa-solid fa-tower-broadcast"></i> ${this.t('drill.gotoTraffic')}
                    </button>
                `,
            };
        }

        if (type === 'callsign') {
            const cs = payload.callsign || '';
            return {
                title: cs,
                html: `<p class="pui-drill-note">${cs}</p>`,
                actions: `
                    <button class="pui-btn-primary" id="pui-drill-watch-pilot">
                        <i class="fa-solid fa-binoculars"></i> ${this.t('drill.addToWatchlist')}
                    </button>
                `,
            };
        }

        return { title: '', html: '' };
    },

    async _fetchSubscriptionData() {
        if (!this._currentUser || !this._supabase) return;

        try {
            const { data, error } = await this._supabase
                .from('subscriptions')
                .select('status, plan_name, current_period_end, amount')
                .eq('user_id', this._currentUser.id)
                .single();

            if (data && !error) {
                const nextDate = new Date(data.current_period_end);
                this._subscription = {
                    status: data.status === 'active' ? 'Active' : 'Inactive',
                    plan: data.plan_name || 'Pro Access',
                    nextPayment: isNaN(nextDate) ? 'Pending' : nextDate.toLocaleDateString('en-US', { timeZone: this._timezone }),
                    price: `$${(data.amount / 100).toFixed(2)} / month`
                };

                if (this._activeTab === 'settings' && this._isOpen) {
                    this._renderContentOnly();
                }
            }
        } catch (err) {
            console.warn("Using default subscription data.");
        }
    },

    async _fetchFlightPlans() {
        if (!this._currentUser || !this._supabase) return;

        try {
            const { data, error } = await this._supabase
                .from('user_flights')
                .select('*')
                .eq('user_id', this._currentUser.id)
                .order('dep_time', { ascending: false })
                .limit(50);

            if (error) throw error;

            this._flightPlansData = data || [];

            if (this._activeTab === 'flight-plan' && this._isOpen) {
                this._renderContentOnly();
            }
        } catch (err) {
            console.error("Error fetching flight plans:", err.message);
        }
    },

    async _fetchInfiniteFlightData(ifUsername) {
        if (!ifUsername) return;

        this._ifData.loading = true;
        this._ifData.error = null;
        if (this._isOpen && (this._activeTab === 'dashboard' || this._activeTab === 'career-deep-dive')) {
            this._renderContentOnly();
        }

        try {
            let ifUserId = null;
            let activeFlightId = null;

            if (typeof window.getLiveFlightData === 'function') {
                const liveFlights = window.getLiveFlightData();
                const activeFlight = liveFlights.find(f =>
                    f.properties &&
                    f.properties.username &&
                    f.properties.username.toLowerCase() === ifUsername.toLowerCase()
                );

                if (activeFlight) {
                    activeFlightId = activeFlight.properties.flightId;
                    ifUserId = activeFlight.properties.userId;
                }
            }

            if (!ifUserId) {
                const userRes = await fetch(`${this._backendUrl}/users`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        discourseNames: [ifUsername],
                        userHashes: [ifUsername]
                    })
                });

                const userData = await userRes.json();
                ifUserId = userData?.users?.[0]?.userId;
            }

            if (!ifUserId) throw new Error('Could not find an Infinite Flight account with that username.');

            this._ifData.userId = ifUserId;

const requests = [
                fetch(`${this._backendUrl}/api/users/${ifUserId}/stats`).then(res => res.json()),
                fetch(`${this._backendUrl}/api/users/${ifUserId}/flights?page=1`).then(res => res.json()),
                fetch(`${this._backendUrl}/api/metadata`).then(res => res.json()).catch(() => null)
            ];

            if (activeFlightId) {
                requests.push(
                    fetch(`${this._backendUrl}/api/flights/${activeFlightId}/history`)
                        .then(res => res.json())
                        .catch(() => null)
                );
            }

            const results = await Promise.all(requests);
            const statsData = results[0];
            const flightsData = results[1];
            const metaJson = results[2];
            const historyData = activeFlightId ? results[3] : null;

            if (metaJson && metaJson.ok) {
                this._aircraftMap = new Map((metaJson.aircraft || []).map(a => [String(a.id).toLowerCase(), a.name]));
                this._liveryMap = new Map((metaJson.liveries || []).map(l => [
                    String(l.id).toLowerCase(), 
                    { liveryName: l.name, aircraftName: l.aircraftName }
                ]));
            }

            this._ifData.stats = statsData.ok ? statsData.stats : null;
            this._ifData.logbook = flightsData.ok ? flightsData.flights : [];
            this._ifData.logbookTotal = flightsData.ok ? flightsData.totalCount : 0;

            if (historyData && historyData.ok) {
                this._ifData.activeHistory = historyData.path;
            }

            if (this._ifData.stats) {
                const lite = {
                    gradeIndex:    this._ifData.stats.gradeDetails?.gradeIndex,
                    totalXP:       this._ifData.stats.totalXP,
                    totalFlights:  this._ifData.logbookTotal,
                };
                this._userPrefs.cached_if_stats = lite;
                this._userPrefs.cached_if_at    = new Date().toISOString();
                this._saveUserPreferences();
            }

            this._ifData.loading = false;

        } catch (err) {
            console.error("Failed to fetch IF data:", err);
            this._ifData.error = err.message;
            this._ifData.loading = false;

            if (this._userPrefs.cached_if_stats) {
                const cached = this._userPrefs.cached_if_stats;
                const ago    = this._userPrefs.cached_if_at
                    ? new Date(this._userPrefs.cached_if_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
                    : 'unknown date';
                this._ifData.stats = {
                    gradeDetails: { gradeIndex: cached.gradeIndex },
                    totalXP:      cached.totalXP,
                    _stale:       true,
                    _staleDate:   ago,
                };
                this._ifData.logbookTotal = cached.totalFlights ?? 0;
                this._ifData.error = null;
            }
        }

        if (this._isOpen && (this._activeTab === 'dashboard' || this._activeTab === 'career-deep-dive')) {
            this._renderContentOnly();
        }
    },

    _inject() {
        const el = document.createElement('div');
        el.id = 'profile-overlay';
        el.className = 'pui-wrapper-layer';
        el.setAttribute('data-theme', this._theme);
        el.setAttribute('data-density', this._density);
        el.innerHTML = `<div class="pui-shell" id="pui-shell"></div>`;
        document.body.appendChild(el);

        // Click outside to close
        el.addEventListener('click', (e) => {
            if (e.target === el) this.close();
        });

        // Keyboard shortcuts: Esc closes; digits 1-6 jump tabs
        document.addEventListener('keydown', (e) => {
            if (!this._isOpen) return;
            if (e.key === 'Escape') { this.close(); return; }
            if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'SELECT') return;
            const tabMap = { '1': 'dashboard', '2': 'career-deep-dive', '3': 'airspace-intel', '4': 'flight-plan', '5': 'watchlist', '6': 'settings' };
            if (tabMap[e.key]) this.switchTab(tabMap[e.key]);
        });

        // Toast container
        const toastContainer = document.createElement('div');
        toastContainer.id = 'pui-toast-container';
        toastContainer.className = 'pui-toast-container';
        document.body.appendChild(toastContainer);

        this._injectStyles();
    },

    /**
     * Builds the full shell. Called on open() and when crossing the onboarding
     * boundary. Inside a normal session, switchTab() uses _renderContentOnly()
     * instead so the dock/top strip don't get rebuilt.
     */
    _render() {
        const shell = document.getElementById('pui-shell');
        if (!shell) return;

        shell.setAttribute('data-active-tab', this._activeTab);

        const showChrome = this._activeTab !== 'onboarding';

        shell.innerHTML = `
            ${showChrome ? this._getTopStripHTML() : ''}
            <main class="pui-content" id="pui-content">
                ${this._getTabContentHTML()}
            </main>
            ${showChrome ? this._getDockHTML() : ''}
        `;

        this._shellBuilt = showChrome;

        if (this._activeTab === 'dashboard') {
            this._updateLiveFlightDOM();
        }

        this._attachListeners();
    },

    /** Rebuilds only the main content area; leaves dock + top strip untouched. */
    _renderContentOnly() {
        const shell = document.getElementById('pui-shell');
        if (!shell) return;

        // If shell wasn't built (e.g. coming out of onboarding), do a full render
        if (!this._shellBuilt && this._activeTab !== 'onboarding') {
            this._render();
            return;
        }

        shell.setAttribute('data-active-tab', this._activeTab);
        const content = document.getElementById('pui-content');
        if (!content) {
            this._render();
            return;
        }

        content.innerHTML = this._getTabContentHTML();

        if (this._activeTab === 'dashboard') {
            this._updateLiveFlightDOM();
        }

        this._attachContentListeners();
    },

    _syncDockActiveState() {
        document.querySelectorAll('.pui-dock-item').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.tab === this._activeTab);
        });
        // Update watchlist live count badge
        const badge = document.getElementById('pui-dock-watchlist-badge');
        const liveCount = Object.values(this._watchedPilotStatus).filter(s => s.isLive).length;
        if (badge) {
            if (liveCount > 0) {
                badge.textContent = liveCount;
                badge.style.display = '';
            } else {
                badge.style.display = 'none';
            }
        }
    },

    _getTopStripHTML() {
        const user = this._currentUser;
        const name = user?.user_metadata?.full_name || user?.user_metadata?.name || 'Captain';
        const initials = name.trim().split(/\s+/).map(w => w[0]).join('').toUpperCase().slice(0, 2);
        const planLabel = this._subscription.plan;

        const themeIcon = this._theme === 'dark' ? 'fa-moon' : 'fa-sun';
        const densityIcon = this._density === 'compact' ? 'fa-grip-lines' : 'fa-grip';
        const densityLabel = this._density === 'compact' ? 'Compact' : 'Cozy';

        return `
            <header class="pui-topstrip">
                <div class="pui-topstrip-left">
                    <div class="pui-brand">
                        <img src="Images/InflightPro.png" alt="Inflight Pro" class="pui-brand-logo">
                    </div>
                </div>
                <div class="pui-topstrip-right">
                    <button class="pui-icon-btn" id="pui-density-btn" title="Density: ${densityLabel} — click to toggle">
                        <i class="fa-solid ${densityIcon}"></i>
                    </button>
                    <button class="pui-icon-btn" id="pui-theme-btn" title="Theme: ${this._theme === 'dark' ? 'Dark' : 'Light'} — click to toggle">
                        <i class="fa-solid ${themeIcon}"></i>
                    </button>
                    <div class="pui-user-chip" title="${name} · ${planLabel}">
                        <span class="pui-user-initials">${initials}</span>
                        <span class="pui-user-meta">
                            <span class="pui-user-name">${name.split(' ')[0]}</span>
                            <span class="pui-user-plan">${planLabel}</span>
                        </span>
                    </div>
                    <button class="pui-icon-btn" id="pui-signout-btn" title="Sign out">
                        <i class="fa-solid fa-arrow-right-from-bracket"></i>
                    </button>
                    <button class="pui-icon-btn pui-icon-btn-close" id="pui-close-btn" title="Close (Esc)">
                        <i class="fa-solid fa-xmark"></i>
                    </button>
                </div>
            </header>
        `;
    },

    _getDockHTML() {
        const allItems = {
            'dashboard':        { icon: 'fa-house',           labelKey: 'tab.dashboard' },
            'career-deep-dive': { icon: 'fa-id-card',         labelKey: 'tab.dossier'   },
            'airspace-intel':   { icon: 'fa-tower-broadcast', labelKey: 'tab.traffic'   },
            'flight-plan':      { icon: 'fa-route',           labelKey: 'tab.dispatch'  },
            'watchlist':        { icon: 'fa-binoculars',      labelKey: 'tab.watchlist' },
            'settings':         { icon: 'fa-sliders',         labelKey: 'tab.settings'  },
        };
        const order = this._resolveDockOrder();
        const navItems = order
            .filter(id => allItems[id])
            .map(id => ({ id, icon: allItems[id].icon, label: this.t(allItems[id].labelKey) }));

        const liveCount = Object.values(this._watchedPilotStatus).filter(s => s.isLive).length;

        return `
            <nav class="pui-dock" aria-label="Main navigation">
                <div class="pui-dock-inner">
                    ${navItems.map(item => {
                        const isActive = this._activeTab === item.id;
                        const isWatch = item.id === 'watchlist';
                        const badgeAttrs = isWatch ? `id="pui-dock-watchlist-badge" style="${liveCount > 0 ? '' : 'display:none;'}"` : '';
                        const badgeText = isWatch && liveCount > 0 ? liveCount : (isWatch ? '' : '');
                        return `
                            <button class="pui-dock-item ${isActive ? 'active' : ''}"
                                    data-tab="${item.id}"
                                    draggable="true"
                                    title="${item.label}">
                                <span class="pui-dock-icon"><i class="fa-solid ${item.icon}"></i></span>
                                <span class="pui-dock-label">${item.label}</span>
                                ${isWatch ? `<span class="pui-dock-badge" ${badgeAttrs}>${badgeText}</span>` : ''}
                            </button>
                        `;
                    }).join('')}
                </div>
            </nav>
        `;
    },

    /**
     * Wire the dock listeners — both tab switching (click) and reordering
     * (drag & drop). Extracted so resetDockOrder() can re-bind after replacing
     * the dock node in place.
     */
    _wireDockListeners() {
        const dock = document.querySelector('.pui-dock');
        if (!dock) return;

        // Click to switch tab
        dock.querySelectorAll('.pui-dock-item').forEach(btn => {
            btn.addEventListener('click', (e) => {
                // Ignore clicks that are the tail end of a drag
                if (btn.classList.contains('dragging')) return;
                this.switchTab(e.currentTarget.dataset.tab);
            });
        });

        // Drag & drop to reorder
        let dragSrc = null;
        dock.querySelectorAll('.pui-dock-item').forEach(item => {
            item.addEventListener('dragstart', (e) => {
                dragSrc = item;
                item.classList.add('dragging');
                // Required for Firefox
                try { e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', item.dataset.tab); } catch (_) {}
            });
            item.addEventListener('dragend', () => {
                item.classList.remove('dragging');
                dock.querySelectorAll('.pui-dock-item.drop-target').forEach(el => el.classList.remove('drop-target'));
                dragSrc = null;
            });
            item.addEventListener('dragover', (e) => {
                if (!dragSrc || dragSrc === item) return;
                e.preventDefault();
                try { e.dataTransfer.dropEffect = 'move'; } catch (_) {}
                item.classList.add('drop-target');
            });
            item.addEventListener('dragleave', () => {
                item.classList.remove('drop-target');
            });
            item.addEventListener('drop', (e) => {
                e.preventDefault();
                item.classList.remove('drop-target');
                if (!dragSrc || dragSrc === item) return;
                const inner = dock.querySelector('.pui-dock-inner');
                if (!inner) return;

                // Insert before/after based on horizontal midpoint
                const rect = item.getBoundingClientRect();
                const after = (e.clientX - rect.left) > rect.width / 2;
                inner.insertBefore(dragSrc, after ? item.nextSibling : item);

                // Persist new order
                const newOrder = Array.from(inner.querySelectorAll('.pui-dock-item')).map(el => el.dataset.tab);
                this.setDockOrder(newOrder);
            });
        });
    },

async _updateLiveFlightDOM() {
        const wrapper = document.getElementById('pui-live-flights-wrapper');
        if (!wrapper) return;

        if (!this._liveFlights || this._liveFlights.length === 0) {
            wrapper.innerHTML = '';
            wrapper.style.display = 'none';
            this._3dViewerHostKey = null;
            this._active3DFlightId = null;
            
            // Premium memory management: Destroy lingering 3D instance if flights clear
            if (typeof AircraftViewer3D !== 'undefined' && typeof AircraftViewer3D.destroy === 'function') {
                AircraftViewer3D.destroy();
            }
            return;
        }

        wrapper.style.display = 'block';

        const flightsWithDispatch = await Promise.all(this._liveFlights.map(async (flight) => {
            let plan = null;
            if (flight.username && flight.departureIcao && flight.arrivalIcao) {
                plan = await FlightDispatchService.getFiledPlan(flight.username, flight.departureIcao, flight.arrivalIcao);
            }
            return { ...flight, _dispatchPlan: plan };
        }));

        const cardsHtmlArray = await Promise.all(flightsWithDispatch.map(async (flight) => {
            const altRaw = flight.position?.alt_ft || 0;
            const alt = Math.round(altRaw).toLocaleString();
            const gs  = Math.round(flight.position?.gs_kt || 0);
            const hdg = String(Math.round(flight.position?.heading_deg || 0)).padStart(3, '0');
            const vs  = Math.round(flight.position?.vs_fpm || 0);
            const dep = flight.departureIcao || '----';
            const arr = flight.arrivalIcao   || '----';
            const cs  = flight.callsign      || 'UNK';
            const acft = flight.aircraft?.aircraftName || 'Unknown Aircraft';

            const plan = flight._dispatchPlan;
            const depGate = plan?.dep_gate ? `<span class="pui-live-gate">GTE ${plan.dep_gate}</span>` : '';
            const arrGate = plan?.arr_gate ? `<span class="pui-live-gate">GTE ${plan.arr_gate}</span>` : '';

            const analytics = await TelemetryAnalyticsEngine.analyze(flight, plan);

            let dispatchHTML = '';
            if (plan) {
                const hours = Math.floor(plan.duration_minutes / 60);
                const mins = plan.duration_minutes % 60;
                
                let dynamicStatsHTML = '';
                if (analytics.isTrackable) {
                    dynamicStatsHTML = `
                        <div class="pui-live-dispatch-item" style="width: 100%; margin-top: 6px;">
                            <div style="display:flex; justify-content:space-between; width:100%; font-size:0.7rem; color:var(--pui-accent);">
                                <span>${analytics.phaseOfFlight}</span>
                                <span>${analytics.time.progressPercent}% Route Complete</span>
                            </div>
                            <div style="width:100%; height:4px; background:rgba(255,255,255,0.1); border-radius:2px; margin-top:4px;">
                                <div style="width:${analytics.time.progressPercent}%; height:100%; background:var(--pui-pos); border-radius:2px;"></div>
                            </div>
                        </div>
                        <div class="pui-live-dispatch-item" style="width: 100%; margin-top: 6px;">
                            <div style="display:flex; justify-content:space-between; width:100%; font-size:0.7rem; color:var(--pui-text-tertiary);">
                                <span>Est. Fuel: ${analytics.fuel.estimatedRemainingLbs.toLocaleString()} lbs rem</span>
                                <span>${analytics.fuel.currentBurnRatePerHour.toLocaleString()} lbs/hr</span>
                            </div>
                        </div>
                    `;
                }

                dispatchHTML = `
                    <div class="pui-live-dispatch-strip">
                        <div class="pui-live-dispatch-tag"><i class="fa-solid fa-file-signature"></i> DISPATCH VERIFIED</div>
                        ${plan.passengers ? `<div class="pui-live-dispatch-item"><i class="fa-solid fa-users"></i> ${plan.passengers} POB</div>` : ''}
                        ${plan.fuel_used ? `<div class="pui-live-dispatch-item"><i class="fa-solid fa-gas-pump"></i> ${plan.fuel_used.toLocaleString()} LBS BLOCK</div>` : ''}
                        ${plan.duration_minutes ? `<div class="pui-live-dispatch-item"><i class="fa-regular fa-clock"></i> ${hours}H ${mins}M EET</div>` : ''}
                        ${dynamicStatsHTML}
                    </div>
                `;
            }

            const vsColor = vs > 100 ? 'var(--pui-pos)' : (vs < -100 ? 'var(--pui-neg)' : 'rgba(255,255,255,0.55)');
            const vsSign  = vs > 0 ? '+' : '';

            let imageUrl = null;
            let imageCredit = '';
            if (typeof window.getLiveFlightData === 'function') {
                const mapFlights = window.getLiveFlightData();
                const mapFlight  = mapFlights.find(f => f.properties?.flightId === flight.flightId);
                if (mapFlight?.properties?.communityImageUrl) {
                    imageUrl    = mapFlight.properties.communityImageUrl;
                    imageCredit = mapFlight.properties.contributorName || '';
                }
            }

            const flightIdStr = String(flight.flightId);
            const is3DActive = (this._active3DFlightId === flightIdStr);
            const canLaunch3D = altRaw > 3000;

            const bgHTML = is3DActive
                ? `<div class="pui-live-bg pui-live-bg-3d" data-3d-host></div>`
                : (imageUrl
                    ? `<div class="pui-live-bg" style="background-image:url('${imageUrl}')"></div>`
                    : `<div class="pui-live-bg pui-live-bg-fallback"></div>`);

            // Integrated Action Buttons inside the layout flow instead of absolute positioning
            const actionButtonHTML = is3DActive ? `
                <button class="pui-btn-ghost pui-close-3d-btn" 
                        style="background: rgba(220, 38, 38, 0.8); color: #fff; border: 1px solid rgba(255,255,255,0.2); backdrop-filter: blur(4px); padding: 6px 12px; height: 34px;">
                    <i class="fa-solid fa-xmark"></i> Close HUD
                </button>
            ` : `
                <button class="pui-btn-ghost pui-launch-3d-btn" 
                        style="background: rgba(0,0,0,0.6); color: #fff; border: 1px solid rgba(255,255,255,0.2); backdrop-filter: blur(4px); padding: 6px 12px; height: 34px;" 
                        data-flight-id="${flightIdStr}" 
                        ${!canLaunch3D ? 'disabled title="Requires altitude over 3,000 ft"' : ''}>
                    <i class="fa-solid fa-vr-cardboard"></i> ${canLaunch3D ? 'Launch 3D HUD' : '3D HUD (Alt > 3k ft)'}
                </button>
            `;

            // Completely hide redundant statistics if the 3D HUD is rendering the PFD
            const statsHTML = is3DActive ? '' : `
                <div class="pui-live-stats">
                    <div class="pui-live-stat">
                        <span class="label">Altitude</span>
                        <span class="value">${alt} <em>ft</em></span>
                    </div>
                    <div class="pui-live-stat">
                        <span class="label">Ground Spd</span>
                        <span class="value">${gs} <em>kt</em></span>
                    </div>
                    <div class="pui-live-stat">
                        <span class="label">Heading</span>
                        <span class="value">${hdg}<em>°</em></span>
                    </div>
                    <div class="pui-live-stat">
                        <span class="label">Vert Spd</span>
                        <span class="value" style="color:${vsColor};">${vsSign}${vs} <em>fpm</em></span>
                    </div>
                </div>
            `;

            return `
                <div class="pui-live-card">
                    ${bgHTML}
                    <div class="pui-live-overlay"></div>
                    <div class="pui-live-content">
                        <div class="pui-live-top">
                            <div class="pui-live-route-pill">
                                <span class="pui-live-icao">${dep}</span>
                                ${depGate}
                                <i class="fa-solid fa-plane pui-live-route-icon"></i>
                                <span class="pui-live-icao">${arr}</span>
                                ${arrGate}
                            </div>
                            <div style="display: flex; align-items: center; gap: 14px;">
                                <div class="pui-live-ident" style="text-align: right;">
                                    <span class="pui-live-acft">${acft}</span>
                                    <span class="pui-live-cs">${cs}</span>
                                </div>
                                ${actionButtonHTML}
                            </div>
                        </div>
                        <div class="pui-live-spacer"></div>
                        ${statsHTML}
                        ${dispatchHTML}
                        ${imageCredit && !is3DActive ? `<div class="pui-live-credit">© ${imageCredit}</div>` : ''}
                    </div>
                </div>
            `;
        }));

        const oldHost = document.querySelector('[data-3d-host]');
        const targetFlight = flightsWithDispatch.find(f => String(f.flightId) === this._active3DFlightId);
        const hostKey = targetFlight ? String(targetFlight.flightId) : null;
        const canReuse = !!oldHost && this._3dViewerHostKey === hostKey && hostKey !== null;

        // --- PREVENT SCROLL RESET ---
        const existingCarousel = wrapper.querySelector('.pui-live-carousel');
        const currentScrollPos = existingCarousel ? existingCarousel.scrollLeft : 0;

        wrapper.innerHTML = `<div class="pui-live-carousel" style="cursor: grab;">${cardsHtmlArray.join('')}</div>`;

        // --- 3D WINDOW STRICT SINGLETON LOGIC ---
        wrapper.querySelectorAll('.pui-launch-3d-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const targetId = e.currentTarget.dataset.flightId;
                
                if (this._active3DFlightId && this._active3DFlightId !== targetId) {
                    if (typeof AircraftViewer3D !== 'undefined' && typeof AircraftViewer3D.destroy === 'function') {
                        AircraftViewer3D.destroy();
                    }
                    this._3dViewerHostKey = null;
                }
                
                this._active3DFlightId = targetId;
                this._updateLiveFlightDOM(); 
            });
        });

        wrapper.querySelectorAll('.pui-close-3d-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                if (typeof AircraftViewer3D !== 'undefined' && typeof AircraftViewer3D.destroy === 'function') {
                    AircraftViewer3D.destroy();
                }
                this._active3DFlightId = null;
                this._updateLiveFlightDOM(); 
            });
        });

        // --- PREMIUM KINETIC SCROLLING ---
        const newCarousel = wrapper.querySelector('.pui-live-carousel');
        if (newCarousel) {
            newCarousel.scrollLeft = currentScrollPos;

            let isDown = false;
            let startX;
            let scrollLeft;
            let velocity = 0;
            let momentumID;
            let lastTimestamp;
            let lastX;
            
            const cancelMomentum = () => {
                if (momentumID) cancelAnimationFrame(momentumID);
            };

            const applyMomentum = () => {
                if (Math.abs(velocity) > 0.5) {
                    newCarousel.scrollLeft -= velocity;
                    velocity *= 0.94; 
                    momentumID = requestAnimationFrame(applyMomentum);
                } else {
                    newCarousel.style.scrollSnapType = 'x mandatory'; 
                }
            };

            newCarousel.addEventListener('mousedown', (e) => {
                if (e.target.closest('button')) return; 
                
                isDown = true;
                cancelMomentum(); 
                newCarousel.style.cursor = 'grabbing';
                newCarousel.style.scrollSnapType = 'none'; 
                
                startX = e.pageX;
                lastX = e.pageX;
                scrollLeft = newCarousel.scrollLeft;
                lastTimestamp = performance.now();
                velocity = 0;
            });

            const handleMouseUpOrLeave = () => {
                if (!isDown) return;
                isDown = false;
                newCarousel.style.cursor = 'grab';
                
                if (Math.abs(velocity) > 2) {
                    applyMomentum();
                } else {
                    newCarousel.style.scrollSnapType = 'x mandatory';
                }
            };

            newCarousel.addEventListener('mouseleave', handleMouseUpOrLeave);
            newCarousel.addEventListener('mouseup', handleMouseUpOrLeave);

            newCarousel.addEventListener('mousemove', (e) => {
                if (!isDown) return;
                e.preventDefault(); 
                
                const currentX = e.pageX;
                const walk = (currentX - startX); 
                newCarousel.scrollLeft = scrollLeft - walk;
                
                const currentTimestamp = performance.now();
                const deltaT = currentTimestamp - lastTimestamp;
                const deltaX = currentX - lastX;
                
                if (deltaT > 0) {
                    velocity = (velocity * 0.4) + ((deltaX / deltaT) * 16 * 0.6); 
                }
                
                lastX = currentX;
                lastTimestamp = currentTimestamp;
            });
        }

        const newHost = wrapper.querySelector('[data-3d-host]');

        if (newHost && targetFlight) {
            if (canReuse) {
                newHost.replaceWith(oldHost);
                AircraftViewer3D.updateFlightData(this._extractPositionForViewer(targetFlight));
            } else {
                newHost.innerHTML = AircraftViewer3D.getHTML();
                
                setTimeout(() => {
                    if (document.contains(newHost)) {
                        AircraftViewer3D
                            .init(targetFlight.aircraft?.aircraftName, this._extractPositionForViewer(targetFlight))
                            .catch(err => console.warn('[ProfileUI] AircraftViewer3D init failed:', err));
                    }
                }, 350);
                
                this._3dViewerHostKey = hostKey;
            }
        } else {
            this._3dViewerHostKey = null;
        }
    },

    /**
     * Normalises a SocketDataHub flight into the position shape that
     * AircraftViewer3D.init / updateFlightData expect. Falls back to map-layer
     * coordinates if the socket payload doesn't carry lat/lon directly, and
     * to safe defaults (Alps, FL350, 450 kt) so the viewer always boots.
     */
    _extractPositionForViewer(flight) {
        const pos = flight?.position || {};
        let lat = pos.lat ?? pos.latitude  ?? null;
        let lon = pos.lon ?? pos.longitude ?? null;

        if ((lat == null || lon == null) && typeof window.getLiveFlightData === 'function') {
            try {
                const mapFlights = window.getLiveFlightData();
                const mapFlight  = mapFlights.find(f => f.properties?.flightId === flight.flightId);
                const coords     = mapFlight?.geometry?.coordinates;
                if (Array.isArray(coords) && coords.length >= 2) {
                    if (lon == null) lon = coords[0];
                    if (lat == null) lat = coords[1];
                }
            } catch (_) { /* defensive: never let coord lookup break the viewer */ }
        }

        return {
            lat:         lat ?? 46.0,
            lon:         lon ?? 7.5,
            alt_ft:      pos.alt_ft      ?? 35000,
            gs_kt:       pos.gs_kt       ?? 450,
            pitch_deg:   pos.pitch_deg   ?? 0,
            roll_deg:    pos.roll_deg    ?? 0,
            heading_deg: pos.heading_deg ?? pos.track ?? 45,
        };
    },

_generateAirspaceHTML() {
        if (!this._airspaceNetwork) return '';
        const report = this._airspaceNetwork.generateNetworkAnalytics();

        if (Object.keys(report.nodes).length === 0) {
             return `<div class="pui-alert pui-alert-info" style="max-width: 600px; margin: 40px auto; text-align: center;">
                        <i class="fa-solid fa-satellite" style="font-size: 1.5rem; margin-bottom: 12px; display: block; opacity: 0.5;"></i>
                        No active network nodes are being monitored. Register an ICAO hub above to begin tracking spatial telemetry.
                    </div>`;
        }

        let html = '<div class="pui-grid-cards">';

        for (const [icao, data] of Object.entries(report.nodes)) {
            let maxSat = 'NORMAL';
            const statuses = data.arrivalQueue.map(b => b.status);
            if (statuses.includes('CRITICAL')) maxSat = 'CRITICAL';
            else if (statuses.includes('SATURATED')) maxSat = 'SATURATED';
            else if (statuses.includes('HEAVY')) maxSat = 'HEAVY';

            let statusColor = 'var(--pui-pos)';
            let statusBg = 'var(--pui-pos-soft)';
            let statusIcon = 'fa-circle-check';
            let plainEnglishSummary = 'Traffic flow is optimal and unrestricted. No delays anticipated.';

            if (maxSat === 'CRITICAL') {
                statusColor = 'var(--pui-neg)';
                statusBg = 'var(--pui-neg-soft)';
                statusIcon = 'fa-triangle-exclamation';
                plainEnglishSummary = 'Critical congestion. Significant delays and holding patterns expected.';
            } else if (maxSat === 'SATURATED') {
                statusColor = 'var(--pui-warn)';
                statusBg = 'var(--pui-warn-soft)';
                statusIcon = 'fa-circle-exclamation';
                plainEnglishSummary = 'Approaching saturation. Sequencing delays likely on arrival.';
            } else if (maxSat === 'HEAVY') {
                statusColor = 'var(--pui-info)';
                statusBg = 'var(--pui-info-soft)';
                statusIcon = 'fa-wave-square';
                plainEnglishSummary = 'Heavy demand. Throughput is high but flow remains controlled.';
            }

            // Heatmap rendering
            const buckets = data.arrivalQueue;
            const maxCount = Math.max(1, ...buckets.map(b => b.count || 0));
            
            // Isolate the traffic arriving strictly within the next hour (first 4 buckets)
            const firstHourInbound = buckets.slice(0, 4).reduce((sum, b) => sum + (b.count || 0), 0);
            
            // Calculate 1-Hour Load against the isolated traffic, not global enroute traffic
            const loadPercentage = Math.min(100, Math.round((firstHourInbound / Math.max(1, data.metrics.effectiveCapacity * 4)) * 100));

            let heatmapHTML = '<div class="pui-intel-heatmap">';
            for(let i = 0; i < Math.min(4, data.arrivalQueue.length); i++) {
                const bucket = data.arrivalQueue[i];
                const intensity = (bucket.count || 0) / maxCount;
                let blockColor = 'var(--pui-border)';
                if (bucket.status === 'CRITICAL') blockColor = 'var(--pui-neg)';
                else if (bucket.status === 'SATURATED') blockColor = 'var(--pui-warn)';
                else if (bucket.status === 'HEAVY') blockColor = 'var(--pui-info)';
                else if (bucket.count > 0) blockColor = 'var(--pui-pos)';

                let tooltipDetail = `${bucket.startMin}-${bucket.endMin}min: ${bucket.count} arrivals`;
                if (bucket.flights && bucket.flights.length > 0) {
                    const flightDetails = bucket.flights.slice(0, 3).map(f => `<span style="font-family:'JetBrains Mono', monospace; color:#fff;">${f.callsign || 'UNKNOWN'}</span> from <span style="font-family:'JetBrains Mono', monospace; color:#fff;">${f.origin}</span> (${f.minutesOut}m)`).join('<br/>');
                    tooltipDetail += `<br/><br/>${flightDetails}`;
                    if (bucket.flights.length > 3) tooltipDetail += `<br/>+${bucket.flights.length - 3} more...`;
                }

                heatmapHTML += `
                    <div class="pui-intel-heatblock" style="background: ${blockColor}; opacity: ${0.3 + intensity * 0.7};">
                        <div class="pui-heatblock-tooltip">
                            <strong>${bucket.label}</strong><br/>
                            ${tooltipDetail}
                        </div>
                    </div>
                `;
            }
            heatmapHTML += '</div>';

            let alertsHTML = '';
            if (data.metrics.highEnergyArrivals > 0) {
                alertsHTML += `<span class="pui-mini-tag" style="background:var(--pui-warn-soft);color:var(--pui-warn);"><i class="fa-solid fa-bolt"></i> ${data.metrics.highEnergyArrivals} HIGH ENERGY</span>`;
            }
            if (data.metrics.heavyAircraftInbound > 0) {
                alertsHTML += `<span class="pui-mini-tag" style="background:var(--pui-info-soft);color:var(--pui-info);"><i class="fa-solid fa-weight-hanging"></i> ${data.metrics.heavyAircraftInbound} HEAVY</span>`;
            }
            if (!data.hubControlState.isFullyControlled) {
                alertsHTML += `<span class="pui-mini-tag" style="background:var(--pui-purple-soft);color:var(--pui-purple);"><i class="fa-solid fa-tower-broadcast"></i> UNCTRL</span>`;
            }

            let topOpsHTML = '';
            if (data.topOperators.arrivals && data.topOperators.arrivals.length > 0) {
                topOpsHTML = data.topOperators.arrivals.slice(0, 3).map(op =>
                    `<span class="pui-chip-soft">${op.name} <em>(${op.count})</em></span>`
                ).join(' ');
            }

            const netFlowColor = data.metrics.netFlowDelta > 0 ? 'var(--pui-pos)' : (data.metrics.netFlowDelta < 0 ? 'var(--pui-neg)' : 'var(--pui-text-primary)');
            const netFlowText = data.metrics.netFlowDelta > 0 ? `+${data.metrics.netFlowDelta}` : data.metrics.netFlowDelta;

            html += `
                <div class="pui-card">
                    <div class="pui-card-header pui-card-header-row">
                        <div class="pui-card-title-group">
                            <i class="fa-solid fa-tower-observation" style="color: var(--pui-text-secondary);"></i>
                            <h3 class="pui-mono-h">${icao}</h3>
                        </div>
                        <span class="pui-status-badge" style="background: ${statusBg}; color: ${statusColor};">${maxSat}</span>
                    </div>
                    <div class="pui-card-body">
                        <div class="pui-assessment-row">
                            <div class="pui-assessment-icon" style="color: ${statusColor};">
                                <i class="fa-solid ${statusIcon}"></i>
                            </div>
                            <div class="pui-assessment-text">
                                <strong>Network Assessment</strong>
                                <span>${plainEnglishSummary}</span>
                            </div>
                        </div>

                        <div class="pui-load-bar-block">
                            <div class="pui-load-bar-head">
                                <span class="pui-eyebrow">1-Hour Load</span>
                                <span class="pui-mono-meta">${loadPercentage}%</span>
                            </div>
                            <div class="pui-load-bar-track">
                                <div class="pui-load-bar-fill" style="width: ${loadPercentage}%; background: ${statusColor};"></div>
                            </div>
                        </div>

                        <div class="pui-intel-stats-quad">
                            <div class="pui-intel-stat">
                                <span class="label">INBOUND</span>
                                <span class="value">${data.metrics.totalInbound}</span>
                            </div>
                            <div class="pui-intel-stat">
                                <span class="label">OUTBOUND</span>
                                <span class="value">${data.metrics.totalOutbound}</span>
                            </div>
                            <div class="pui-intel-stat">
                                <span class="label">NET FLOW</span>
                                <span class="value" style="color: ${netFlowColor};">${netFlowText}</span>
                            </div>
                            <div class="pui-intel-stat">
                                <span class="label">METERED</span>
                                <span class="value" style="${data.metrics.meteredAircraftCount > 0 ? 'color: var(--pui-info);' : ''}">${data.metrics.meteredAircraftCount}</span>
                            </div>
                        </div>

                        <div class="pui-intel-stats-tri" style="grid-template-columns: 1fr;">
                            <div class="pui-intel-stat">
                                <span class="label">TERMINAL AREA DENSITY (TMA)</span>
                                <span class="value-sm">${data.metrics.inTerminalArea} aircraft tracking</span>
                            </div>
                        </div>

                        ${alertsHTML ? `<div class="pui-mini-tag-row">${alertsHTML}</div>` : ''}

                        <div class="pui-section-head">
                            <span class="pui-eyebrow">4-Hour Saturation Map</span>
                            <span class="pui-mono-meta-sm">CAP ${data.metrics.effectiveCapacity}/15m</span>
                        </div>
                        ${heatmapHTML}

                        ${topOpsHTML ? `<div class="pui-top-ops"><span class="pui-eyebrow">Top Arrivals</span> ${topOpsHTML}</div>` : ''}

                        <div class="pui-card-footer" style="justify-content: space-between; display: flex; align-items: center;">
                            <button class="pui-btn-primary pui-intel-3d-btn" data-icao="${icao}" style="background: rgba(57, 255, 20, 0.15); color: #39ff14; border: 1px solid rgba(57, 255, 20, 0.3);">
                                <i class="fa-solid fa-cube"></i> 3D Terminal Twin
                            </button>
                            <button class="pui-btn-ghost pui-intel-remove-btn" data-icao="${icao}">
                                <i class="fa-solid fa-link-slash"></i> Unlink Node
                            </button>
                        </div>
                    </div>
                </div>
            `;
        }
        html += '</div>';
        return html;
    },

    _updateAirspaceDOM() {
        const container = document.getElementById('pui-intel-dynamic-container');
        if (container && this._airspaceNetwork) {
            container.innerHTML = this._generateAirspaceHTML();

            // Handle Unlinking Nodes
            container.querySelectorAll('.pui-intel-remove-btn').forEach(btn => {
                btn.addEventListener('click', (e) => {
                    const icao = e.currentTarget.dataset.icao;
                    const currentNodes = Array.from(this._airspaceNetwork._activeNodes).filter(n => n !== icao);
                    this._airspaceNetwork.setActiveNodes(currentNodes);
                    this._updateAirspaceDOM();
                });
            });

            // Handle Premium 3D Terminal Twin Launch
            container.querySelectorAll('.pui-intel-3d-btn').forEach(btn => {
                btn.addEventListener('click', async (e) => {
                    const icao = e.currentTarget.dataset.icao.toUpperCase();
                    
                    // Fetch the airport cache if it hasn't been loaded by the Dispatch tab yet
                    if (!this._airportCache) {
                        try {
                            const res = await fetch('https://raw.githubusercontent.com/mwgg/Airports/master/airports.json');
                            this._airportCache = await res.json();
                        } catch (err) {
                            console.error('[ProfileUI] Failed to load airport cache for 3D Viewer', err);
                            return;
                        }
                    }

                    const aptData = this._airportCache[icao];
                    if (aptData) {
                        // Dynamically import the new AirportViewer3D module
                        import('./AirportViewer3D.js').then(module => {
                            module.AirportViewer3D.init(icao, aptData.lat, aptData.lon);
                        }).catch(err => {
                            console.error('[ProfileUI] Could not load AirportViewer3D module', err);
                        });
                    } else {
                        console.warn(`[ProfileUI] No coordinates found for ICAO: ${icao}`);
                    }
                });
            });
        }
    },

    _getTimezoneOptionsHTML(selectedTz) {
        try {
            const zones = Intl.supportedValuesOf('timeZone');
            return zones.map(tz => `<option value="${tz}" ${tz === selectedTz ? 'selected' : ''}>${tz.replace(/_/g, ' ')}</option>`).join('');
        } catch (e) {
            return `<option value="${selectedTz}" selected>${selectedTz}</option>`;
        }
    },

    // A helper method to clear the dispatch form back to Create mode
    _resetFlightForm() {
        this._editingFlightId = null;
        
        const formTitle = document.getElementById('pui-dispatch-form-title');
        if (formTitle) formTitle.innerHTML = `<i class="fa-solid fa-file-pen"></i> Generate dispatch`;

        const submitBtn = document.getElementById('pui-submit-flight-btn');
        if (submitBtn) submitBtn.innerHTML = `<i class="fa-solid fa-paper-plane"></i> File flight plan`;

        const cancelBtn = document.getElementById('pui-cancel-edit-btn');
        if (cancelBtn) cancelBtn.style.display = 'none';

        const inputs = [
            'pui-new-callsign', 'pui-new-aircraft', 'pui-new-dep', 'pui-new-arr', 
            'pui-new-dep-gate', 'pui-new-arr-gate', 'pui-new-time', 'pui-new-duration', 
            'pui-new-pax', 'pui-new-fuel'
        ];
        inputs.forEach(id => {
            const el = document.getElementById(id);
            if (el) el.value = '';
        });
    },

    /** Premium Background Processor for routing Time Estimates */
    async _autoCalculateRouteEET(depIcao, arrIcao) {
        if (!depIcao || !arrIcao || depIcao.length !== 4 || arrIcao.length !== 4) return null;

        try {
            // Load and cache airport dictionary dynamically if not already present
            if (!this._airportCache) {
                const res = await fetch('https://raw.githubusercontent.com/mwgg/Airports/master/airports.json');
                if (!res.ok) throw new Error('Network error');
                this._airportCache = await res.json();
            }

            const origin = this._airportCache[depIcao.toUpperCase()];
            const dest = this._airportCache[arrIcao.toUpperCase()];

            if (!origin || !dest) return null;

            // Haversine Distance Calculation
            const toRad = (value) => value * Math.PI / 180;
            const R = 3440.065; // Earth radius in Nautical Miles
            const dLat = toRad(dest.lat - origin.lat);
            const dLon = toRad(dest.lon - origin.lon);
            const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                      Math.cos(toRad(origin.lat)) * Math.cos(toRad(dest.lat)) *
                      Math.sin(dLon / 2) * Math.sin(dLon / 2);
            const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
            const distanceNM = R * c;

            // Premium heuristic: 450kt block average + 30m padding for SID/STAR routing
            const cruiseHours = distanceNM / 450;
            const totalMinutes = Math.round((cruiseHours * 60) + 30);

            return totalMinutes;
        } catch (e) {
            console.warn('[ProfileUI] Auto-EET failed:', e);
            return null; // Silent failover back to manual input
        }
    },

_getTabContentHTML() {
        if (this._activeTab === 'onboarding') {
            return `
                <div class="pui-onboarding-container pui-fade-in">
                    <div class="pui-onboarding-card">
                        <div class="pui-onboarding-header">
                            <div class="pui-onboarding-icon"><i class="fa-solid fa-plane-departure"></i></div>
                            <h2>Welcome aboard.</h2>
                            <p>Thank you for subscribing to Pro Access. Let's set up your flight deck.</p>
                        </div>
                        <div class="pui-onboarding-body">

                            <div class="pui-input-group">
                                <label>Choose your theme</label>
                                <div class="pui-theme-options pui-theme-options-row">
                                    <label class="pui-theme-option">
                                        <input type="radio" name="onboarding-theme" value="light" ${this._theme === 'light' ? 'checked' : ''}>
                                        <i class="fa-solid fa-sun"></i>
                                        <span>Light</span>
                                    </label>
                                    <label class="pui-theme-option">
                                        <input type="radio" name="onboarding-theme" value="dark" ${this._theme === 'dark' ? 'checked' : ''}>
                                        <i class="fa-solid fa-moon"></i>
                                        <span>Dark</span>
                                    </label>
                                </div>
                            </div>

                            <div class="pui-input-group">
                                <label>Infinite Flight Username</label>
                                <div class="pui-input-wrapper">
                                    <i class="fa-solid fa-plane pui-input-icon"></i>
                                    <input type="text" id="onboarding-if-username" class="pui-input has-icon" placeholder="Community Forum Name">
                                </div>
                                <p class="pui-help-text">We use this to fetch your live flights and career stats.</p>
                            </div>

                            <p class="pui-help-text" style="text-align:center;margin-top:18px;">
                                You can change these any time from Settings.
                            </p>

                            <button class="pui-btn-primary pui-btn-block" id="onboarding-complete-btn">
                                Complete setup
                            </button>
                        </div>
                    </div>
                </div>
            `;
        }

        if (this._activeTab === 'airspace-intel') {
            return `
                <div class="pui-tab-header pui-fade-in">
                    <div>
                        <h2>Traffic</h2>
                        <p>Real-time predictive multi-node telemetry. Forecasting congestion across active hubs.</p>
                    </div>
                    <div class="pui-tab-header-actions">
                        <div class="pui-input-wrapper" style="width:160px;">
                            <i class="fa-solid fa-location-crosshairs pui-input-icon"></i>
                            <input type="text" id="pui-intel-new-node" class="pui-input has-icon pui-icao-input" placeholder="ICAO" maxlength="4">
                        </div>
                        <button class="pui-btn-primary" id="pui-intel-add-node">
                            <i class="fa-solid fa-satellite-dish"></i> Monitor hub
                        </button>
                    </div>
                </div>
                <div id="pui-intel-dynamic-container" class="pui-fade-in">
                    ${this._generateAirspaceHTML()}
                </div>
            `;
        }

        if (this._activeTab === 'career-deep-dive') {
            const user = this._currentUser;
            const ifUsername = user?.user_metadata?.if_username || '';
            const fullName = user?.user_metadata?.full_name || user?.user_metadata?.name || 'Captain';
            
            // Extract Initials for Avatar
            const initials = fullName.split(/\s+/).map(w => w[0]).join('').toUpperCase().slice(0, 2);

            // 1. Missing Link State
            if (!ifUsername) {
                return `
                    <div class="pui-tab-header pui-fade-in">
                        <div><h2>Pilot Dossier</h2><p>Comprehensive career analytics and high-level flight statistics.</p></div>
                    </div>
                    <div class="pui-alert pui-alert-info pui-fade-in" style="grid-column: 1 / -1; margin-top: 24px; padding: 24px; text-align: center; flex-direction: column; gap: 12px;">
                        <i class="fa-solid fa-link-slash" style="font-size: 2rem; opacity: 0.5;"></i>
                        <span style="font-size: 1.1rem; font-weight: 600;">Account Not Linked</span>
                        <span>Link your Infinite Flight account in Settings to dynamically render your career dossier.</span>
                    </div>`;
            }

            // 2. Loading State (Premium Skeleton)
            if (this._ifData.loading) {
                return `
                    <div class="pui-dossier-hero pui-skeleton" style="height: 240px; border-radius: var(--pui-radius-xl); margin-bottom: var(--pui-gap-lg);"></div>
                    <div class="pui-stats-grid" style="margin-bottom: var(--pui-gap-lg);">
                        <div class="pui-stat-card pui-skeleton" style="height: 110px;"></div>
                        <div class="pui-stat-card pui-skeleton" style="height: 110px;"></div>
                        <div class="pui-stat-card pui-skeleton" style="height: 110px;"></div>
                    </div>
                    <div class="pui-skeleton" style="height: 200px; border-radius: var(--pui-radius-lg);"></div>
                `;
            }

            // 3. Error State
            if (this._ifData.error) {
                return `
                    <div class="pui-tab-header pui-fade-in"><h2>Pilot Dossier</h2></div>
                    <div class="pui-alert pui-alert-error pui-fade-in"><i class="fa-solid fa-circle-xmark"></i> Data Retrieval Failed: ${this._ifData.error}</div>`;
            }

            // 4. Premium Data Extraction & Processing
            const stats = this._ifData.stats || {};
            const logbook = this._ifData.logbook || [];
            
            const grade = stats.gradeDetails?.gradeIndex || '—';
            const xp = stats.totalXP || 0;
            const totalFlights = this._ifData.logbookTotal || 0;
            const landings = stats.landingCount || 0;
            const violations = stats.violations || 0;
            
            // Accurately calculate total hours (API provides flightTime in minutes, fallback to logbook sum)
            const flightTimeMins = stats.flightTime || logbook.reduce((sum, f) => sum + (f.totalTime || 0), 0);
            const flightTimeHrs = (flightTimeMins / 60).toLocaleString(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 });

            // Advanced Analytics: Safety Index
            const safetyRatio = landings > 0 ? Math.max(0, ((landings - violations) / landings) * 100) : 100;
            const safetyColor = safetyRatio >= 98 ? 'var(--pui-pos)' : safetyRatio >= 90 ? 'var(--pui-warn)' : 'var(--pui-neg)';

            // Advanced Analytics: Fleet Utilization (Top 3)
            const fleetMap = {};
            logbook.forEach(f => {
                const aId = f.aircraftId || f.aircraftID;
                const lId = f.liveryId || f.liveryID;
                if (aId) {
                    const resolvedName = this._resolveAircraftName(aId, lId);
                    fleetMap[resolvedName] = (fleetMap[resolvedName] || 0) + 1;
                }
            });
            const topFleet = Object.entries(fleetMap).sort((a, b) => b[1] - a[1]).slice(0, 3);
            const maxFleetCount = topFleet.length > 0 ? topFleet[0][1] : 1;

            const fleetHTML = topFleet.length > 0 ? topFleet.map((a, i) => `
                <div class="pui-fleet-bar-wrapper">
                    <div class="pui-fleet-bar-label">
                        <span class="pui-mono-meta" style="color: var(--pui-text-primary);">${a[0]}</span> 
                        <span class="pui-mono-meta-sm">${a[1]} flts</span>
                    </div>
                    <div class="pui-fleet-bar-bg">
                        <div class="pui-fleet-bar-fill" style="width: ${Math.max(4, (a[1] / maxFleetCount) * 100)}%; background: ${i === 0 ? 'var(--pui-accent)' : 'var(--pui-text-tertiary)'};"></div>
                    </div>
                </div>
            `).join('') : '<div class="pui-empty-inline">Insufficient logbook data for fleet analytics.</div>';

            // Base Background for Hero
            const bgStyle = this._coverUrl 
                ? `background-image: url('${this._coverUrl.replace(/'/g, "&apos;")}'); background-size: cover; background-position: center;` 
                : `background: linear-gradient(135deg, var(--pui-bg-surface) 0%, var(--pui-bg-base) 100%);`;

            return `
                <div class="pui-dossier-hero pui-fade-in" style="${bgStyle}">
                    <div class="pui-dossier-hero-overlay">
                        <div class="pui-dossier-hero-content">
                            <div class="pui-dossier-profile-group">
                                <div class="pui-dossier-avatar">${initials}</div>
                                <div class="pui-dossier-identity">
                                    <h2 class="pui-dossier-name">${fullName}</h2>
                                    <div class="pui-dossier-username"><i class="fa-solid fa-plane" style="font-size: 0.75rem; opacity: 0.6;"></i> ${ifUsername}</div>
                                    ${this._bio ? `<div class="pui-dossier-bio">${this._bio}</div>` : ''}
                                </div>
                            </div>
                            <button class="pui-dossier-grade-badge pui-stat-card-clickable" data-drill="grade" title="View Grade Requirements">
                                <span class="pui-grade-label">PILOT GRADE</span>
                                <span class="pui-grade-value">${grade}</span>
                                <i class="fa-solid fa-expand pui-grade-expand"></i>
                            </button>
                        </div>

                        <div class="pui-dossier-telemetry-strip">
                            <button class="pui-dossier-tele-item pui-stat-card-clickable" data-drill="xp" title="View XP Breakdown">
                                <span class="label">Total XP</span>
                                <span class="value">${xp.toLocaleString()}</span>
                            </button>
                            <div class="pui-dossier-tele-divider"></div>
                            <button class="pui-dossier-tele-item pui-stat-card-clickable" data-drill="flights" title="View Flight History">
                                <span class="label">Flights Flown</span>
                                <span class="value">${totalFlights.toLocaleString()}</span>
                            </button>
                            <div class="pui-dossier-tele-divider"></div>
                            <div class="pui-dossier-tele-item">
                                <span class="label">Flight Time</span>
                                <span class="value">${flightTimeHrs} <em style="font-size: 0.7rem; font-weight: 500; font-style: normal; color: var(--pui-text-secondary);">HRS</em></span>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="pui-dossier-analytics-grid pui-fade-in">
                    <div class="pui-card pui-analytics-card">
                        <div class="pui-card-header pui-card-header-row">
                            <h3><i class="fa-solid fa-shield-check" style="color: var(--pui-accent); margin-right:8px;"></i>Safety Profile</h3>
                        </div>
                        <div class="pui-card-body pui-safety-body">
                            <div class="pui-safety-metrics">
                                <div class="pui-safety-stat">
                                    <span class="label">Total Landings</span>
                                    <span class="value">${landings.toLocaleString()}</span>
                                </div>
                                <div class="pui-safety-stat">
                                    <span class="label">Violations</span>
                                    <span class="value" style="${violations > 0 ? 'color: var(--pui-neg);' : 'color: var(--pui-pos);'}">${violations.toLocaleString()}</span>
                                </div>
                            </div>
                            <div class="pui-safety-index">
                                <div class="pui-safety-index-label">Safety Index</div>
                                <div class="pui-safety-index-value" style="color: ${safetyColor};">${safetyRatio.toFixed(1)}%</div>
                                <div class="pui-safety-bar-track">
                                    <div class="pui-safety-bar-fill" style="width: ${safetyRatio}%; background: ${safetyColor};"></div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="pui-card pui-analytics-card">
                        <div class="pui-card-header pui-card-header-row">
                            <h3><i class="fa-solid fa-plane-tail" style="color: var(--pui-accent); margin-right:8px;"></i>Fleet Utilization</h3>
                            <span class="pui-mono-meta-sm">Top 3 Types</span>
                        </div>
                        <div class="pui-card-body pui-fleet-body">
                            ${fleetHTML}
                        </div>
                    </div>
                </div>

                <div class="pui-fade-in" style="margin-bottom: var(--pui-gap-lg);">
                    ${this._getTrendsCardHTML()}
                </div>

                <div class="pui-fade-in" style="margin-bottom: var(--pui-gap-lg);">
                    ${CareerModule && typeof CareerModule.getHTML === 'function' ? CareerModule.getHTML(this._ifData) : ''}
                </div>

                ${this._ifData.logbook?.length > 0 ? `
                <div class="pui-fade-in" style="margin-top: var(--pui-gap-lg);">
                    ${this._getPersonalRecordsHTML()}
                </div>` : ''}
            `;
        }

        if (this._activeTab === 'watchlist') {
            return this._getWatchlistTabHTML();
        }

        if (this._activeTab === 'dashboard') {
            const user = this._currentUser;
            const name = user?.user_metadata?.full_name || user?.user_metadata?.name || 'Captain';
            const firstName = name.trim().split(/\s+/)[0];
            const ifUsername = user?.user_metadata?.if_username || '';

            const formatter = new Intl.DateTimeFormat('en-US', { hour: 'numeric', hourCycle: 'h23', timeZone: this._timezone });
            const hourString = formatter.format(new Date());
            const hour = parseInt(hourString, 10);
            const greeting = hour < 12 ? this.t('greet.morning') : hour < 17 ? this.t('greet.afternoon') : this.t('greet.evening');
            const dateLocale = this._locale === 'en' ? 'en-US' : this._locale;
            const dateStr = new Date().toLocaleDateString(dateLocale, { weekday: 'long', month: 'long', day: 'numeric', timeZone: this._timezone });

            let statsStrip = '';
            if (this._ifData.stats) {
                const grade   = this._ifData.stats.gradeDetails?.gradeIndex;
                const xp      = this._ifData.stats.totalXP?.toLocaleString();
                const flights = this._ifData.logbookTotal?.toLocaleString();
                const staleTag = this._ifData.stats._stale
                    ? `<span class="pui-strip-sep">·</span><span title="Live data unavailable — showing cached data from ${this._ifData.stats._staleDate}" class="pui-strip-stale"><i class="fa-solid fa-clock-rotate-left"></i> cached ${this._ifData.stats._staleDate}</span>`
                    : '';
                statsStrip = `<div class="pui-stat-strip">
                    ${grade   ? `<span>Grade ${grade}</span><span class="pui-strip-sep">·</span>` : ''}
                    ${xp      ? `<span>${xp} XP</span><span class="pui-strip-sep">·</span>` : ''}
                    ${flights ? `<span>${flights} flights</span>` : ''}
                    ${staleTag}
                </div>`;
            } else if (this._ifData.loading) {
                statsStrip = `<div class="pui-stat-strip" style="opacity:0.4;">${this.t('common.loading')}</div>`;
            }

            let recentFlightsHTML = '';
            if (!ifUsername) {
                recentFlightsHTML = `<div class="pui-empty-inline">Link your Infinite Flight account in Settings to see recent activity.</div>`;
            } else if (this._ifData.loading) {
                recentFlightsHTML = `
                    <div class="pui-flight-row"><div class="pui-skeleton" style="width:120px;height:13px;flex:1;"></div><div class="pui-skeleton" style="width:60px;height:9px;"></div></div>
                    <div class="pui-flight-row"><div class="pui-skeleton" style="width:100px;height:13px;flex:1;"></div><div class="pui-skeleton" style="width:50px;height:9px;"></div></div>
                    <div class="pui-flight-row"><div class="pui-skeleton" style="width:130px;height:13px;flex:1;"></div><div class="pui-skeleton" style="width:55px;height:9px;"></div></div>
                `;
            } else if (this._ifData.logbook?.length > 0) {
                recentFlightsHTML = this._ifData.logbook.slice(0, 6).map((flight) => {
                    const dep    = flight.originAirport      || 'N/A';
                    const arr    = flight.destinationAirport || 'N/A';
                    const hrs    = (flight.totalTime / 60).toFixed(1);
                    const server = flight.server || 'Unknown';
                    const dateObj = new Date(flight.created);
                    const isRecent = (Date.now() - dateObj.getTime()) < (86400000 * 2);
                    const timeStr  = isRecent ? 'Recently' : dateObj.toLocaleDateString(dateLocale, { month: 'short', day: 'numeric', timeZone: this._timezone });
                    const depAttr = dep !== 'N/A' ? `data-drill="icao" data-icao="${dep}"` : '';
                    const arrAttr = arr !== 'N/A' ? `data-drill="icao" data-icao="${arr}"` : '';
                    const cs = flight.callsign || 'N/A';
                    const csAttr = cs !== 'N/A' ? `data-drill="callsign" data-callsign="${cs}"` : '';
                    
                    const planAttr = (dep !== 'N/A' && arr !== 'N/A') ? `data-action="plan-route" data-dep="${dep}" data-arr="${arr}"` : '';
                    
                    return `
                        <div class="pui-flight-row">
                            <div class="pui-flight-route">
                                <span class="pui-flight-icao pui-drillable" ${depAttr}>${dep}</span>
                                <span class="pui-flight-arrow">→</span>
                                <span class="pui-flight-icao pui-drillable" ${arrAttr}>${arr}</span>
                            </div>
                            <div class="pui-flight-meta">
                                <span class="pui-drillable" ${csAttr}>${cs}</span>
                                <span>·</span>
                                <span>${server}</span>
                                <span>·</span>
                                <span>${hrs}h</span>
                            </div>
                            <div class="pui-flight-time">${timeStr}</div>
                            ${planAttr ? `<button class="pui-icon-btn pui-plan-quick-btn" ${planAttr} title="Plan this route"><i class="fa-solid fa-route"></i></button>` : ''}
                        </div>`;
                }).join('');
            } else {
                recentFlightsHTML = `<div class="pui-empty-inline">${this.t('empty.recent')}</div>`;
            }

            let nextDispatch = '';
            if (this._flightPlansData?.length > 0) {
                const next   = this._flightPlansData[0];
                const depTime = new Date(next.dep_time);
                const diffMs  = depTime - Date.now();
                const diffH   = Math.floor(diffMs / 3600000);
                const diffM   = Math.floor((diffMs % 3600000) / 60000);
                const countdown = diffMs > 0 ? (diffH > 0 ? `In ${diffH}h ${diffM}m` : `In ${diffM}m`) : 'Departed';
                const hours = Math.floor(next.duration_minutes / 60);
                const mins  = next.duration_minutes % 60;
                nextDispatch = `
                    <div class="pui-dispatch-route">
                        <div class="pui-dispatch-side">
                            <span class="code pui-drillable" ${next.dep_icao ? `data-drill="icao" data-icao="${next.dep_icao}"` : ''}>${next.dep_icao || '----'}</span>
                            ${next.dep_gate ? `<span class="gate">Gate ${next.dep_gate}</span>` : ''}
                        </div>
                        <div class="pui-dispatch-path">
                            <i class="fa-solid fa-plane"></i>
                            <span>${hours}h ${mins}m</span>
                        </div>
                        <div class="pui-dispatch-side pui-dispatch-side-right">
                            <span class="code pui-drillable" ${next.arr_icao ? `data-drill="icao" data-icao="${next.arr_icao}"` : ''}>${next.arr_icao || '----'}</span>
                            ${next.arr_gate ? `<span class="gate">Gate ${next.arr_gate}</span>` : ''}
                        </div>
                    </div>
                    <div class="pui-dispatch-info">
                        <div class="pui-dispatch-row">
                            <span>Aircraft</span>
                            <strong>${next.aircraft_type || 'N/A'}</strong>
                        </div>
                        <div class="pui-dispatch-row">
                            <span>Callsign</span>
                            <strong class="pui-mono">${next.callsign || 'N/A'}</strong>
                        </div>
                        <div class="pui-dispatch-row">
                            <span>Departure</span>
                            <strong style="color:var(--pui-accent);">${countdown}</strong>
                        </div>
                        ${next.passengers ? `<div class="pui-dispatch-row"><span>POB</span><strong>${next.passengers} pax</strong></div>` : ''}
                    </div>`;
            } else {
                nextDispatch = `
                    <div class="pui-empty-block">
                        <i class="fa-regular fa-calendar"></i>
                        <span>${this.t('empty.dispatch')}</span>
                    </div>`;
            }

            return `
                <div class="pui-home-header pui-fade-in">
                    <div>
                        <h1 class="pui-home-greeting">${greeting}, ${firstName}.</h1>
                        ${statsStrip}
                    </div>
                    <div class="pui-home-date">${dateStr}</div>
                </div>

                <div id="pui-live-flights-wrapper" style="display:none;"></div>

                <div class="pui-home-grid pui-fade-in">
                    <section class="pui-card pui-home-recent">
                        <div class="pui-card-eyebrow">Recent Flights</div>
                        <div class="pui-flight-list">${recentFlightsHTML}</div>
                    </section>
                    <section class="pui-card pui-home-dispatch">
                        <div class="pui-card-eyebrow">Next Departure</div>
                        ${nextDispatch}
                    </section>
                </div>
            `;
        }

if (this._activeTab === 'flight-plan') {
    return FlightDispatchUI.getTabHTML(this);
}

        if (this._activeTab === 'settings') {
            const user = this._currentUser;
            const name = user?.user_metadata?.full_name || user?.user_metadata?.name || '';
            const email = user?.email || '';
            const ifUsername = user?.user_metadata?.if_username || '';

            // Language options
            const langOptionsHTML = Object.entries(this._LOCALES).map(([code, info]) => {
                const sel = code === this._locale ? 'selected' : '';
                return `<option value="${code}" ${sel}>${info.flag} ${info.label}</option>`;
            }).join('');

            // Accent swatches
            const accentSwatchesHTML = Object.entries(this._ACCENT_PRESETS).map(([key, preset]) => {
                const variant = this._theme === 'dark' ? preset.dark : preset.light;
                const isActive = key === this._accent;
                return `
                    <button type="button"
                            class="pui-accent-swatch ${isActive ? 'active' : ''}"
                            data-accent="${key}"
                            title="${preset.label}"
                            style="background:${variant.c};">
                        ${isActive ? '<i class="fa-solid fa-check"></i>' : ''}
                    </button>`;
            }).join('');

            // Dock order preview
            const dockPreviewHTML = this._resolveDockOrder().map(id => {
                const labelKeys = {
                    'dashboard': 'tab.dashboard', 'career-deep-dive': 'tab.dossier',
                    'airspace-intel': 'tab.traffic', 'flight-plan': 'tab.dispatch',
                    'watchlist': 'tab.watchlist', 'settings': 'tab.settings',
                };
                return `<span class="pui-dock-chip">${this.t(labelKeys[id] || id)}</span>`;
            }).join('');

            return `
                <div class="pui-tab-header pui-fade-in">
                    <div>
                        <h2>${this.t('header.settings.title')}</h2>
                        <p>${this.t('header.settings.sub')}</p>
                    </div>
                </div>

                <div class="pui-settings-grid pui-fade-in">
                    <div class="pui-settings-main" style="display: flex; flex-direction: column; gap: var(--pui-gap-md);">
                        <div class="pui-card">
                            <div class="pui-card-header"><h3>${this.t('set.profile')}</h3></div>
                            <div class="pui-card-body">
                                <div class="pui-input-group">
                                    <label>${this.t('set.fullName')}</label>
                                    <div class="pui-input-wrapper">
                                        <i class="fa-solid fa-user pui-input-icon"></i>
                                        <input type="text" id="pui-edit-name" class="pui-input has-icon" value="${name}">
                                    </div>
                                </div>

                                <div class="pui-input-group">
                                    <label>${this.t('set.email')}</label>
                                    <div class="pui-input-wrapper">
                                        <i class="fa-solid fa-envelope pui-input-icon"></i>
                                        <input type="email" class="pui-input has-icon" value="${email}" disabled>
                                    </div>
                                    <p class="pui-help-text">Email address cannot be changed directly.</p>
                                </div>

                                <div class="pui-input-group">
                                    <label>${this.t('set.ifUsername')}</label>
                                    <div class="pui-input-wrapper">
                                        <i class="fa-solid fa-plane pui-input-icon"></i>
                                        <input type="text" id="pui-edit-if-username" class="pui-input has-icon" value="${ifUsername}" placeholder="Infinite Flight Community Forum Name">
                                    </div>
                                    <p class="pui-help-text">Link your account to automatically log your flights and display your stats.</p>
                                </div>

                                <div class="pui-input-group">
                                    <label>${this.t('set.timezone')}</label>
                                    <div class="pui-input-wrapper">
                                        <i class="fa-solid fa-earth-americas pui-input-icon"></i>
                                        <select id="pui-edit-timezone" class="pui-input has-icon pui-select">
                                            ${this._getTimezoneOptionsHTML(this._timezone)}
                                        </select>
                                        <i class="fa-solid fa-chevron-down pui-select-chevron"></i>
                                    </div>
                                    <p class="pui-help-text">Used to sync departure times and telemetry across your devices.</p>
                                </div>

                                <div class="pui-input-group">
                                    <label>${this.t('set.password')}</label>
                                    <div class="pui-input-wrapper">
                                        <i class="fa-solid fa-lock pui-input-icon"></i>
                                        <input type="password" id="pui-edit-password" class="pui-input has-icon" placeholder="Leave blank to keep current">
                                    </div>
                                </div>

                                <div id="pui-settings-msg" class="pui-alert" style="display: none;"></div>

                                <div class="pui-form-actions">
                                    <button class="pui-btn-primary" id="pui-save-btn">${this.t('common.save')}</button>
                                </div>
                            </div>
                        </div>

                        <div class="pui-card">
                            <div class="pui-card-header"><h3>${this.t('set.personality')}</h3></div>
                            <div class="pui-card-body">
                                <div class="pui-input-group">
                                    <label>${this.t('set.bio')}</label>
                                    <div class="pui-input-wrapper">
                                        <i class="fa-solid fa-quote-left pui-input-icon"></i>
                                        <input type="text" id="pui-edit-bio" class="pui-input has-icon" maxlength="140"
                                               value="${(this._bio || '').replace(/"/g, '&quot;')}"
                                               placeholder="${this.t('set.bioPlaceholder')}">
                                    </div>
                                    <p class="pui-help-text">
                                        <span id="pui-bio-counter">${(this._bio || '').length}</span>/140 — ${this.t('set.bioHelp')}
                                    </p>
                                </div>
                                <div class="pui-input-group" style="margin-bottom:0;">
                                    <label>${this.t('set.cover')}</label>
                                    <div class="pui-input-wrapper">
                                        <i class="fa-solid fa-image pui-input-icon"></i>
                                        <input type="url" id="pui-edit-cover" class="pui-input has-icon"
                                               value="${(this._coverUrl || '').replace(/"/g, '&quot;')}"
                                               placeholder="${this.t('set.coverPlaceholder')}">
                                    </div>
                                    <p class="pui-help-text">${this.t('set.coverHelp')}</p>
                                </div>
                            </div>
                        </div>

                        <div class="pui-card">
                            <div class="pui-card-header pui-card-header-row">
                                <h3>${this.t('set.dockOrder')}</h3>
                                <button class="pui-btn-ghost pui-btn-sm" id="pui-dock-reset-btn" type="button">
                                    <i class="fa-solid fa-rotate-left"></i> ${this.t('common.reset')}
                                </button>
                            </div>
                            <div class="pui-card-body">
                                <div class="pui-dock-preview">${dockPreviewHTML}</div>
                                <p class="pui-help-text">${this.t('set.dockOrderHelp')}</p>
                            </div>
                        </div>
                    </div>

                    <div class="pui-settings-aside">
                        <div class="pui-card">
                            <div class="pui-card-header"><h3>${this.t('set.appearance')}</h3></div>
                            <div class="pui-card-body">
                                <div class="pui-input-group">
                                    <label>${this.t('set.theme')}</label>
                                    <div class="pui-theme-options">
                                        <label class="pui-theme-option">
                                            <input type="radio" name="pui-theme" value="light" ${this._theme === 'light' ? 'checked' : ''}>
                                            <i class="fa-solid fa-sun"></i>
                                            <span>${this.t('set.theme.light')}</span>
                                        </label>
                                        <label class="pui-theme-option">
                                            <input type="radio" name="pui-theme" value="dark" ${this._theme === 'dark' ? 'checked' : ''}>
                                            <i class="fa-solid fa-moon"></i>
                                            <span>${this.t('set.theme.dark')}</span>
                                        </label>
                                    </div>
                                </div>
                                <div class="pui-input-group">
                                    <label>${this.t('set.density')}</label>
                                    <div class="pui-theme-options">
                                        <label class="pui-theme-option">
                                            <input type="radio" name="pui-density" value="cozy" ${this._density === 'cozy' ? 'checked' : ''}>
                                            <i class="fa-solid fa-grip"></i>
                                            <span>${this.t('set.density.cozy')}</span>
                                        </label>
                                        <label class="pui-theme-option">
                                            <input type="radio" name="pui-density" value="compact" ${this._density === 'compact' ? 'checked' : ''}>
                                            <i class="fa-solid fa-grip-lines"></i>
                                            <span>${this.t('set.density.compact')}</span>
                                        </label>
                                    </div>
                                </div>
                                <div class="pui-input-group" style="margin-bottom:0;">
                                    <label>${this.t('set.accent')}</label>
                                    <div class="pui-accent-grid" id="pui-accent-grid">${accentSwatchesHTML}</div>
                                    <p class="pui-help-text">${this.t('set.accentHelp')}</p>
                                </div>
                            </div>
                        </div>

                        <div class="pui-card">
                            <div class="pui-card-header"><h3>${this.t('set.language')}</h3></div>
                            <div class="pui-card-body">
                                <div class="pui-input-group" style="margin-bottom:0;">
                                    <div class="pui-input-wrapper">
                                        <i class="fa-solid fa-language pui-input-icon"></i>
                                        <select id="pui-edit-locale" class="pui-input has-icon pui-select">
                                            ${langOptionsHTML}
                                        </select>
                                        <i class="fa-solid fa-chevron-down pui-select-chevron"></i>
                                    </div>
                                    <p class="pui-help-text">${this.t('set.languageHelp')}</p>
                                </div>
                            </div>
                        </div>

                        <div class="pui-card">
                            <div class="pui-card-header"><h3>${this.t('set.billing')}</h3></div>
                            <div class="pui-card-body">
                                <div class="pui-plan-box">
                                    <div class="pui-plan-header">
                                        <h4>${this._subscription.plan}</h4>
                                        <span class="pui-status-badge ${this._subscription.status === 'Active' ? 'pos' : 'neg'}">${this._subscription.status}</span>
                                    </div>
                                    <p class="pui-plan-price">${this._subscription.price}</p>
                                    <p class="pui-plan-renewal">Next payment · ${this._subscription.nextPayment}</p>
                                </div>
                                <div id="pui-billing-msg" class="pui-alert" style="display: none; margin-top: 14px;"></div>
                                <div class="pui-billing-actions">
                                    <button class="pui-btn-secondary" id="pui-billing-update-btn">
                                        <i class="fa-solid fa-credit-card"></i> Update payment method
                                    </button>
                                    <button class="pui-btn-danger-outline" id="pui-billing-cancel-btn">
                                        <i class="fa-solid fa-ban"></i> Cancel subscription
                                    </button>
                                </div>
                            </div>
                        </div>

                        <div class="pui-card">
                            <div class="pui-card-header"><h3>${this.t('set.support')}</h3></div>
                            <div class="pui-card-body pui-action-list-body">
                                <div class="pui-action-list">
                                    <a href="terms.html" target="_blank" class="pui-action-link">
                                        <span class="pui-action-icon"><i class="fa-solid fa-file-contract"></i></span>
                                        <span class="pui-action-text">Terms of Use</span>
                                        <i class="fa-solid fa-arrow-up-right-from-square pui-action-external"></i>
                                    </a>
                                    <a href="privacy.html" target="_blank" class="pui-action-link">
                                        <span class="pui-action-icon"><i class="fa-solid fa-shield-halved"></i></span>
                                        <span class="pui-action-text">Privacy Policy</span>
                                        <i class="fa-solid fa-arrow-up-right-from-square pui-action-external"></i>
                                    </a>
                                    <a href="https://discord.gg/deH7ftjDxY" target="_blank" class="pui-action-link">
                                        <span class="pui-action-icon" style="background: rgba(88, 101, 242, 0.15); color: #5865F2;"><i class="fa-brands fa-discord"></i></span>
                                        <span class="pui-action-text">Discord Community</span>
                                        <i class="fa-solid fa-arrow-up-right-from-square pui-action-external"></i>
                                    </a>
                                    <a href="mailto:inflightCustomer@gmail.com" class="pui-action-link">
                                        <span class="pui-action-icon"><i class="fa-solid fa-envelope"></i></span>
                                        <span class="pui-action-text">Email Support</span>
                                        <i class="fa-solid fa-arrow-right pui-action-external"></i>
                                    </a>
                                </div>
                            </div>
                        </div>

                    </div>
                </div>
            `;
        }
    },

    _showDeleteConfirmation(flight) {
        return new Promise((resolve) => {
            // Remove existing if a stray one was left behind
            const existing = document.getElementById('pui-custom-confirm');
            if (existing) existing.remove();

            const overlay = document.createElement('div');
            overlay.id = 'pui-custom-confirm';
            overlay.className = 'pui-wrapper-layer';
            overlay.setAttribute('data-theme', this._theme);
            overlay.setAttribute('data-density', this._density);
            overlay.style.zIndex = '10000'; // Sit above the main shell

            const route = `${flight.dep_icao || 'N/A'} &rarr; ${flight.arr_icao || 'N/A'}`;
            const cs = flight.callsign || 'UNK';

            overlay.innerHTML = `
                <div class="pui-confirm-box pui-fade-in">
                    <div class="pui-confirm-header">
                        <div class="pui-confirm-icon"><i class="fa-solid fa-plane-slash"></i></div>
                        <h3>Delete Dispatch</h3>
                    </div>
                    <div class="pui-confirm-body">
                        <p>Are you sure you want to permanently delete this flight plan?</p>
                        <div class="pui-confirm-flight-plate">
                            <span class="pui-ticket-cs" style="margin: 0;">${cs}</span>
                            <span class="pui-confirm-route">${route}</span>
                        </div>
                    </div>
                    <div class="pui-confirm-actions">
                        <button class="pui-btn-ghost" id="pui-confirm-cancel">Keep Flight</button>
                        <button class="pui-btn-danger" id="pui-confirm-proceed">Delete</button>
                    </div>
                </div>
            `;

            document.body.appendChild(overlay);

            // Force reflow to trigger the CSS transition
            requestAnimationFrame(() => {
                requestAnimationFrame(() => {
                    overlay.classList.add('pui-open');
                });
            });

            const cleanup = (result) => {
                overlay.classList.remove('pui-open');
                setTimeout(() => overlay.remove(), 240); // Match var(--pui-ease) timing
                resolve(result);
            };

            // Event Listeners for the modal
            document.getElementById('pui-confirm-cancel').addEventListener('click', () => cleanup(false));
            document.getElementById('pui-confirm-proceed').addEventListener('click', () => cleanup(true));
            
            // Click background to cancel
            overlay.addEventListener('click', (e) => {
                if (e.target === overlay) cleanup(false);
            });

            // Escape key to cancel
            const escHandler = (e) => {
                if (e.key === 'Escape') {
                    cleanup(false);
                    document.removeEventListener('keydown', escHandler);
                }
            };
            document.addEventListener('keydown', escHandler);
        });
    },

_showCancellationModal() {
        const existing = document.getElementById('pui-custom-confirm');
        if (existing) existing.remove();

        const overlay = document.createElement('div');
        overlay.id = 'pui-custom-confirm';
        overlay.className = 'pui-wrapper-layer';
        overlay.setAttribute('data-theme', this._theme);
        overlay.setAttribute('data-density', this._density);
        overlay.style.zIndex = '10000'; // Sit above the main shell

        overlay.innerHTML = `
            <div class="pui-confirm-box pui-fade-in" style="max-width: 440px;">
                <div class="pui-confirm-header" style="padding-bottom: 8px;">
                    <div class="pui-confirm-icon"><i class="fa-solid fa-ban"></i></div>
                    <h3>Cancel Subscription</h3>
                </div>
                <div class="pui-confirm-body">
                    <p style="margin-bottom: 24px;">Please select the payment method you used to upgrade to Pro Access. We will route you to the correct secure portal to manage your billing.</p>
                    
                    <div style="display: flex; flex-direction: column; gap: 12px;">
                        <button class="pui-btn-secondary" id="pui-cancel-stripe-btn" style="padding: 14px; font-size: 0.95rem; justify-content: flex-start; border-color: var(--pui-border-strong);">
                            <i class="fa-brands fa-stripe" style="font-size: 1.8rem; color: #6366f1; width: 40px;"></i>
                            <div style="display: flex; flex-direction: column; align-items: flex-start; gap: 2px;">
                                <span>Apple Pay, Google Pay, or Card</span>
                                <span style="font-size: 0.7rem; color: var(--pui-text-tertiary); font-weight: 500;">Manage via Stripe Billing Portal</span>
                            </div>
                        </button>

                        <button class="pui-btn-secondary" id="pui-cancel-paypal-btn" style="padding: 14px; font-size: 0.95rem; justify-content: flex-start; border-color: var(--pui-border-strong);">
                            <i class="fa-brands fa-paypal" style="font-size: 1.5rem; color: #00457C; width: 40px;"></i>
                            <div style="display: flex; flex-direction: column; align-items: flex-start; gap: 2px;">
                                <span>PayPal</span>
                                <span style="font-size: 0.7rem; color: var(--pui-text-tertiary); font-weight: 500;">Manage via PayPal AutoPay Settings</span>
                            </div>
                        </button>
                    </div>
                </div>
                <div class="pui-confirm-actions" style="justify-content: center; border-top: none; padding-top: 0;">
                    <button class="pui-btn-ghost" id="pui-confirm-cancel" style="width: 100%;">Keep Subscription</button>
                </div>
            </div>
        `;

        document.body.appendChild(overlay);

        // Force reflow to trigger the CSS transition
        requestAnimationFrame(() => {
            requestAnimationFrame(() => {
                overlay.classList.add('pui-open');
            });
        });

        const cleanup = () => {
            overlay.classList.remove('pui-open');
            setTimeout(() => overlay.remove(), 240); // Match var(--pui-ease) timing
            document.removeEventListener('keydown', escHandler);
        };

        // Event Listeners for the modal
        document.getElementById('pui-confirm-cancel').addEventListener('click', cleanup);
        
        overlay.addEventListener('click', (e) => {
            if (e.target === overlay) cleanup();
        });

        const escHandler = (e) => {
            if (e.key === 'Escape') cleanup();
        };
        document.addEventListener('keydown', escHandler);

        // --- PAYPAL ROUTE ---
        document.getElementById('pui-cancel-paypal-btn').addEventListener('click', () => {
            window.open('https://www.paypal.com/myaccount/autopay/', '_blank');
            cleanup();
            this._showMessage(
                'pui-billing-msg', 
                'Opened PayPal in a new tab. Please log in to manage your automatic payments.', 
                'info'
            );
        });

        // --- STRIPE ROUTE ---
        document.getElementById('pui-cancel-stripe-btn').addEventListener('click', async () => {
            const btn = document.getElementById('pui-cancel-stripe-btn');
            const originalHtml = btn.innerHTML; // Store original state to revert on fail
            btn.innerHTML = '<i class="fa-solid fa-circle-notch fa-spin" style="width: 40px; font-size: 1.2rem;"></i> Preparing Stripe Portal...';
            btn.style.pointerEvents = 'none';

            try {
                // Call the Stripe Portal Edge Function
                const { data, error } = await this._supabase.functions.invoke('create-stripe-portal', {
                    body: { return_url: window.location.href }
                });

                // Catch networking/Supabase function invocation errors
                if (error) {
                    throw new Error(error.message || "Failed to reach billing server.");
                }

                // Catch custom errors returned from the Deno script (e.g., no customer found)
                if (data?.error) {
                    throw new Error(data.error);
                }

                if (!data?.url) {
                    throw new Error("Portal URL missing from response.");
                }

                window.location.href = data.url;
                cleanup();

            } catch (err) {
                console.warn("[ProfileUI] Stripe automation failed:", err.message);
                
                // Revert button state so the user isn't stuck loading
                btn.innerHTML = originalHtml;
                btn.style.pointerEvents = 'auto';
                
                // Notify user of the failure and transition to email fallback
                this._showMessage(
                    'pui-billing-msg', 
                    `Portal issue: ${err.message} Opening manual email cancellation draft.`, 
                    'error'
                );
                
                // Graceful fallback to the email system
                const userEmail = this._currentUser?.email || 'Unknown Email';
                const ifUsername = this._currentUser?.user_metadata?.if_username || 'Not Linked';
                const userId = this._currentUser?.id || 'Unknown ID';

                const subject = encodeURIComponent("Cancellation Request - Pro Access (Stripe)");
                const body = encodeURIComponent(
                    `Hello Inflight Pro Support,\n\n` +
                    `I would like to formally request a cancellation of my Pro Access subscription.\n\n` +
                    `Account Details:\n` +
                    `• Email: ${userEmail}\n` +
                    `• IF Username: ${ifUsername}\n` +
                    `• Account ID: ${userId}\n\n` +
                    `I understand that my premium access will remain active until the end of my current billing cycle.\n\n` +
                    `Thank you.`
                );

                window.location.href = `mailto:inflightCustomer@gmail.com?subject=${subject}&body=${body}`;
                cleanup();
            }
        });
    },

    _showMessage(msgDivId, msg, type) {
        const msgDiv = document.getElementById(msgDivId);
        if (msgDiv) {
            msgDiv.textContent = msg;
            msgDiv.style.display = 'block';
            msgDiv.className = `pui-alert pui-alert-${type}`;
        }
    },

    _setLoading(btnId, isLoading, originalText) {
        const btn = document.getElementById(btnId);
        if (!btn) return;

        if (isLoading) {
            btn.disabled = true;
            btn.innerHTML = `<i class="fa-solid fa-circle-notch fa-spin"></i> Processing…`;
            btn.style.opacity = '0.7';
        } else {
            btn.disabled = false;
            btn.innerHTML = originalText;
            btn.style.opacity = '1';
        }
    },

    /**
     * Wires up the full shell (top strip + dock + content). Called after _render().
     */
    _attachListeners() {
        // Top strip
        document.getElementById('pui-close-btn')?.addEventListener('click', () => this.close());
        document.getElementById('pui-signout-btn')?.addEventListener('click', async () => {
            if (this._supabase) {
                await this._supabase.auth.signOut();
                this.close();
            }
        });
        document.getElementById('pui-theme-btn')?.addEventListener('click', () => {
            this.cycleTheme();
            this._refreshTopStripIcons();
        });
        document.getElementById('pui-density-btn')?.addEventListener('click', () => {
            this.cycleDensity();
            this._refreshTopStripIcons();
        });

        // Dock — clicks + drag/drop reorder. Centralized in _wireDockListeners
        // so resetDockOrder() can re-bind after replacing the dock node.
        this._wireDockListeners();

        this._attachContentListeners();
    },

    _refreshTopStripIcons() {
        const themeBtn = document.getElementById('pui-theme-btn');
        const densityBtn = document.getElementById('pui-density-btn');
        if (themeBtn) {
            themeBtn.innerHTML = `<i class="fa-solid ${this._theme === 'dark' ? 'fa-moon' : 'fa-sun'}"></i>`;
            themeBtn.title = `Theme: ${this._theme === 'dark' ? 'Dark' : 'Light'} — click to toggle`;
        }
        if (densityBtn) {
            densityBtn.innerHTML = `<i class="fa-solid ${this._density === 'compact' ? 'fa-grip-lines' : 'fa-grip'}"></i>`;
            densityBtn.title = `Density: ${this._density === 'compact' ? 'Compact' : 'Cozy'} — click to toggle`;
        }
    },

_attachContentListeners() {
        // ─── Delegated drill-down handler ─────────────────────────────────
        // Any element with data-drill="<type>" inside the content area opens
        // the corresponding detail modal. payload reads from sibling data-*
        // attributes (data-icao, data-callsign). One handler covers all tabs.
const contentRoot = document.getElementById('pui-content');
        if (contentRoot && !contentRoot.dataset.drillBound) {
            contentRoot.dataset.drillBound = '1';
            contentRoot.addEventListener('click', (e) => {
                // 1. Drill-down handler
                const drillTarget = e.target.closest('[data-drill]');
                if (drillTarget && contentRoot.contains(drillTarget)) {
                    e.stopPropagation();
                    const type = drillTarget.dataset.drill;
                    const payload = {
                        icao:     drillTarget.dataset.icao,
                        callsign: drillTarget.dataset.callsign,
                    };
                    this._showDrillDown(type, payload);
                    return;
                }

                // 2. Quick Plan Route handler
                const planTarget = e.target.closest('[data-action="plan-route"]');
                if (planTarget && contentRoot.contains(planTarget)) {
                    e.stopPropagation();
                    const dep = planTarget.dataset.dep;
                    const arr = planTarget.dataset.arr;
                    this.switchTab('flight-plan');
                    
                    // Wait for tab switch to render DOM, then populate
                    setTimeout(() => {
                        const depInput = document.getElementById('pui-new-dep');
                        const arrInput = document.getElementById('pui-new-arr');
                        if (depInput) depInput.value = dep;
                        if (arrInput) arrInput.value = arr;
                        
                        // Manually dispatch a blur event to trigger the predictive EET calculator
                        if (depInput) depInput.dispatchEvent(new Event('blur'));
                    }, 150);
                    return;
                }
            });
        }

        // ─── Career Deep Dive (Dossier) Listeners ─────────────────────────
        if (this._activeTab === 'career-deep-dive') {
            if (typeof CareerModule !== 'undefined' && typeof CareerModule.attachListeners === 'function') {
                CareerModule.attachListeners(this._ifData, this._backendUrl, () => {
                    this._renderContentOnly();
                });
            }
        }

        if (this._activeTab === 'onboarding') {
            const themeRadios = document.querySelectorAll('input[name="onboarding-theme"]');
            themeRadios.forEach(radio => {
                radio.addEventListener('change', (e) => {
                    this.setTheme(e.target.value, true);
                });
            });

            document.getElementById('onboarding-complete-btn')?.addEventListener('click', async () => {
                const ifUsername = document.getElementById('onboarding-if-username')?.value.trim();
                const selectedTheme = document.querySelector('input[name="onboarding-theme"]:checked')?.value || 'light';

                this._setLoading('onboarding-complete-btn', true, 'Completing setup');

                try {
                    const { data, error } = await this._supabase.auth.updateUser({
                        data: {
                            if_username: ifUsername,
                            theme: selectedTheme,
                            density: this._density,
                            onboarding_complete: true
                        }
                    });

                    if (error) throw error;

                    this._currentUser = data.user;

                    if (ifUsername) {
                        this._fetchInfiniteFlightData(ifUsername);
                    }

                    this._activeTab = 'dashboard';
                    this._render();

                } catch (error) {
                    console.error("Onboarding Error:", error);
                    alert("Failed to save setup preferences: " + error.message);
                    this._setLoading('onboarding-complete-btn', false, 'Complete setup');
                }
            });
        }

        if (this._activeTab === 'airspace-intel') {
            document.getElementById('pui-intel-add-node')?.addEventListener('click', () => {
                const input = document.getElementById('pui-intel-new-node');
                const icao = input.value.trim().toUpperCase();
                if (icao.length >= 3 && this._airspaceNetwork) {
                    if (!this._airspaceNetwork._hubRegistry.has(icao)) {
                        this._airspaceNetwork.registerNode(icao, 0, 0);
                    }
                    const currentNodes = Array.from(this._airspaceNetwork._activeNodes);
                    if (!currentNodes.includes(icao)) {
                        currentNodes.push(icao);
                        this._airspaceNetwork.setActiveNodes(currentNodes);
                        input.value = '';
                        this._updateAirspaceDOM();
                    }
                }
            });

            document.querySelectorAll('.pui-intel-remove-btn').forEach(btn => {
                btn.addEventListener('click', (e) => {
                    const icao = e.currentTarget.dataset.icao;
                    if (this._airspaceNetwork) {
                        const currentNodes = Array.from(this._airspaceNetwork._activeNodes).filter(n => n !== icao);
                        this._airspaceNetwork.setActiveNodes(currentNodes);
                        this._updateAirspaceDOM();
                    }
                });
            });
        }

        if (this._activeTab === 'flight-plan') {
    FlightDispatchUI.attachListeners(this);

    // Submit / Edit Action — Supabase work stays in the host
    document.getElementById('pui-submit-flight-btn')?.addEventListener('click', async () => {
        const callsign = document.getElementById('pui-new-callsign').value.trim();
        const aircraft = document.getElementById('pui-new-aircraft').value;
        const depIcao  = document.getElementById('pui-new-dep').value.trim().toUpperCase();
        const arrIcao  = document.getElementById('pui-new-arr').value.trim().toUpperCase();
        const duration = parseInt(document.getElementById('pui-new-duration').value);
        const depTime  = document.getElementById('pui-new-time').value;
        const depGate  = document.getElementById('pui-new-dep-gate').value.trim();
        const arrGate  = document.getElementById('pui-new-arr-gate').value.trim();
        const pax      = parseInt(document.getElementById('pui-new-pax').value);
        const fuel     = parseInt(document.getElementById('pui-new-fuel').value);

        if (!callsign || !aircraft || !depIcao || !arrIcao || isNaN(duration) || !depTime) {
            this._showMessage('pui-add-flight-msg', 'Please fill in all required routing & aircraft details.', 'error');
            return;
        }

        const loadingText = this._editingFlightId
            ? '<i class="fa-solid fa-check"></i> Update flight plan'
            : '<i class="fa-solid fa-paper-plane"></i> File flight plan';
        this._setLoading('pui-submit-flight-btn', true, loadingText);

        try {
            const newFlightPlan = {
                user_id: this._currentUser.id,
                if_username: this._currentUser.user_metadata?.if_username || null,
                dep_time: new Date(depTime).toISOString(),
                duration_minutes: duration,
                aircraft_type: aircraft,
                callsign: callsign,
                dep_icao: depIcao,
                arr_icao: arrIcao,
                dep_gate: depGate || null,
                arr_gate: arrGate || null,
                passengers: isNaN(pax) ? null : pax,
                fuel_used: isNaN(fuel) ? null : fuel,
            };

            if (this._editingFlightId) {
                const { error } = await this._supabase
                    .from('user_flights')
                    .update(newFlightPlan)
                    .eq('flight_id', this._editingFlightId);
                if (error) throw error;
                this._showMessage('pui-add-flight-msg', 'Flight plan updated successfully!', 'success');
            } else {
                const { error } = await this._supabase
                    .from('user_flights')
                    .insert([newFlightPlan]);
                if (error) throw error;
                this._showMessage('pui-add-flight-msg', 'Flight plan saved successfully!', 'success');
            }

            setTimeout(() => {
                this._fetchFlightPlans();
                FlightDispatchUI.resetForm();
            }, 1000);

        } catch (err) {
            console.error('Error saving flight plan:', err);
            this._showMessage('pui-add-flight-msg', err.message || 'Error saving flight plan.', 'error');
            this._setLoading('pui-submit-flight-btn', false, loadingText);
        }
    });
}

        if (this._activeTab === 'settings') {
            const themeRadios = document.querySelectorAll('input[name="pui-theme"]');
            themeRadios.forEach(radio => {
                radio.addEventListener('change', (e) => {
                    this.setTheme(e.target.value, true);
                    this._refreshTopStripIcons();
                    // Refresh accent swatches so the visible swatch color matches
                    // the new theme's variant (each preset has light/dark variants).
                    this._refreshAccentSwatches();
                });
            });

            const densityRadios = document.querySelectorAll('input[name="pui-density"]');
            densityRadios.forEach(radio => {
                radio.addEventListener('change', (e) => {
                    this.setDensity(e.target.value, true);
                    this._refreshTopStripIcons();
                });
            });

            // ─── Accent color swatches ─────────────────────────────────────
            document.querySelectorAll('.pui-accent-swatch').forEach(btn => {
                btn.addEventListener('click', () => {
                    const key = btn.dataset.accent;
                    if (!key) return;
                    this.setAccent(key, true);
                    this._refreshAccentSwatches();
                });
            });

            // ─── Language selector (live re-render on change) ──────────────
            document.getElementById('pui-edit-locale')?.addEventListener('change', (e) => {
                this.setLocale(e.target.value, true);
                // setLocale triggers a full re-render — no further wiring needed
            });

            // ─── Pilot bio (live counter + save to local state on input) ───
            const bioInput = document.getElementById('pui-edit-bio');
            const bioCounter = document.getElementById('pui-bio-counter');
            bioInput?.addEventListener('input', () => {
                if (bioCounter) bioCounter.textContent = String(bioInput.value.length);
            });

            // ─── Dock order reset ──────────────────────────────────────────
            document.getElementById('pui-dock-reset-btn')?.addEventListener('click', async () => {
                await this.resetDockOrder();
                // Refresh the dock-order preview chips inline
                const preview = document.querySelector('.pui-dock-preview');
                if (preview) {
                    const labelKeys = {
                        'dashboard': 'tab.dashboard', 'career-deep-dive': 'tab.dossier',
                        'airspace-intel': 'tab.traffic', 'flight-plan': 'tab.dispatch',
                        'watchlist': 'tab.watchlist', 'settings': 'tab.settings',
                    };
                    preview.innerHTML = this._resolveDockOrder()
                        .map(id => `<span class="pui-dock-chip">${this.t(labelKeys[id] || id)}</span>`)
                        .join('');
                }
            });

            document.getElementById('pui-save-btn')?.addEventListener('click', async () => {
                const newName = document.getElementById('pui-edit-name')?.value.trim();
                const newIfUsername = document.getElementById('pui-edit-if-username')?.value.trim();
                const newTimezone = document.getElementById('pui-edit-timezone')?.value;
                const newPassword = document.getElementById('pui-edit-password')?.value;
                const newBio   = document.getElementById('pui-edit-bio')?.value || '';
                const newCover = document.getElementById('pui-edit-cover')?.value.trim() || '';
                const currentTheme = this._theme;
                const currentDensity = this._density;

                let updates = { data: {} };

                if (newName) {
                    updates.data.full_name = newName;
                    updates.data.name = newName;
                }

                if (newIfUsername !== undefined) {
                    updates.data.if_username = newIfUsername;
                }

                if (newTimezone) {
                    updates.data.timezone = newTimezone;
                    this._timezone = newTimezone;
                }

                updates.data.theme = currentTheme;
                updates.data.density = currentDensity;

                // Personalization fields — bundled with the main Save button so
                // the user can edit bio + cover and submit them along with the
                // rest. Trim bio to 140 chars (matches input maxlength).
                updates.data.pilot_bio   = newBio.slice(0, 140);
                updates.data.cover_url   = newCover.slice(0, 500);
                updates.data.locale      = this._locale;
                updates.data.accent_color= this._accent;
                this._bio      = updates.data.pilot_bio;
                this._coverUrl = updates.data.cover_url;

                if (newPassword) {
                    updates.password = newPassword;
                }

                this._setLoading('pui-save-btn', true, this.t('common.save'));

                try {
                    const { error } = await this._supabase.auth.updateUser(updates);
                    if (error) throw error;
                    this._showMessage('pui-settings-msg', 'Settings saved successfully.', 'success');

                    if (newIfUsername && newIfUsername !== this._currentUser?.user_metadata?.if_username) {
                        this._fetchInfiniteFlightData(newIfUsername);
                    }
                } catch (error) {
                    console.error("Save error:", error);
                    this._showMessage('pui-settings-msg', error.message || 'Failed to save settings.', 'error');
                } finally {
                    this._setLoading('pui-save-btn', false, this.t('common.save'));
                }
            });

            document.getElementById('pui-billing-update-btn')?.addEventListener('click', () => {
                this._showMessage('pui-billing-msg', 'Redirecting to billing portal…', 'success');
            });

            document.getElementById('pui-billing-cancel-btn')?.addEventListener('click', () => {
                this._showCancellationModal();
            });
        }

        if (this._activeTab === 'watchlist') {
            const addBtn   = document.getElementById('pui-watchlist-add-btn');
            const input    = document.getElementById('pui-watchlist-input');
            const dropdown = document.getElementById('pui-watchlist-dropdown');

            const doAdd = (overrideUsername = null) => {
                const username = overrideUsername || input?.value.trim();
                if (!username) return;
                
                input.value = '';
                if (dropdown) dropdown.style.display = 'none';
                
                this._addToWatchlist(username);
            };

            addBtn?.addEventListener('click', () => doAdd());
            
            input?.addEventListener('keydown', (e) => { 
                if (e.key === 'Enter') {
                    e.preventDefault();
                    doAdd();
                }
            });

            // Premium Live Autocomplete Logic
            input?.addEventListener('input', (e) => {
                const val = e.target.value.toLowerCase().trim();
                if (!val) {
                    dropdown.style.display = 'none';
                    return;
                }

                const activeFlights = this._currentAllFlights || [];
                const matches = activeFlights.filter(f => f.username && f.username.toLowerCase().includes(val));

                // Deduplicate users in case they have multiple ghosts/sessions
                const uniqueMatches = [];
                const seen = new Set();
                for (const m of matches) {
                    if (!seen.has(m.username.toLowerCase())) {
                        seen.add(m.username.toLowerCase());
                        uniqueMatches.push(m);
                    }
                }

                if (uniqueMatches.length === 0) {
                    dropdown.style.display = 'none';
                    return;
                }

                // Inject rich dropdown content
                dropdown.innerHTML = uniqueMatches.slice(0, 5).map(m => `
                    <div class="pui-autocomplete-item" data-username="${m.username}">
                        <div class="pui-ac-icon"><i class="fa-solid fa-plane"></i></div>
                        <div class="pui-ac-details">
                            <div class="pui-ac-name">${m.username}</div>
                            <div class="pui-ac-meta">${m.callsign || 'UNK'} • ${m.aircraft?.aircraftName || 'Unknown Aircraft'}</div>
                        </div>
                    </div>
                `).join('');

                dropdown.style.display = 'block';

                // Bind click events to new dropdown items
                dropdown.querySelectorAll('.pui-autocomplete-item').forEach(item => {
                    item.addEventListener('click', (ev) => {
                        const selectedUser = ev.currentTarget.dataset.username;
                        input.value = selectedUser;
                        doAdd(selectedUser);
                    });
                });
            });

            // Close dropdown if clicked outside or lost focus (with delay to allow click event)
            input?.addEventListener('blur', () => {
                setTimeout(() => {
                    if (dropdown) dropdown.style.display = 'none';
                }, 200);
            });

            document.querySelectorAll('.pui-watchlist-remove-btn').forEach(btn => {
                btn.addEventListener('click', (e) => {
                    const id       = e.currentTarget.dataset.id;
                    const username = e.currentTarget.dataset.username;
                    this._removeFromWatchlist(id, username);
                });
            });

            const notifToggle = document.getElementById('pui-watchlist-notif-toggle');
            notifToggle?.addEventListener('change', async () => {
                this._userPrefs.notification_watchlist_enabled = notifToggle.checked;
                await this._saveUserPreferences();
            });
        }
    },

    // ═══════════════════════════════════════════════════════════════════════
    // WATCHLIST + USER PREFERENCES (preserved from original)
    // ═══════════════════════════════════════════════════════════════════════

    async _fetchWatchlist() {
        if (!this._currentUser || !this._supabase) return;
        try {
            const { data, error } = await this._supabase
                .from('user_watchlist')
                .select('id, watched_username, added_at')
                .eq('user_id', this._currentUser.id)
                .order('added_at', { ascending: false });
            if (error) throw error;
            this._watchlist = data || [];
        } catch (err) {
            console.warn('[ProfileUI] Could not load watchlist:', err.message);
        }
    },

    async _fetchUserPreferences() {
        if (!this._currentUser || !this._supabase) return;
        try {
            const { data, error } = await this._supabase
                .from('user_preferences')
                .select('*')
                .eq('user_id', this._currentUser.id)
                .single();

            if (data && !error) {
                if (typeof data.notification_watchlist_enabled === 'boolean') {
                    this._userPrefs.notification_watchlist_enabled = data.notification_watchlist_enabled;
                }
                if (data.cached_if_stats) {
                    this._userPrefs.cached_if_stats = data.cached_if_stats;
                    this._userPrefs.cached_if_at    = data.cached_if_at;
                }
            }
        } catch (err) {
            console.warn('[ProfileUI] No user preferences row found, using defaults.');
        }
    },

    async _saveUserPreferences() {
        if (!this._currentUser || !this._supabase) return;
        try {
            await this._supabase.from('user_preferences').upsert({
                user_id: this._currentUser.id,
                notification_watchlist_enabled: this._userPrefs.notification_watchlist_enabled,
                cached_if_stats: this._userPrefs.cached_if_stats,
                cached_if_at:    this._userPrefs.cached_if_at,
            }, { onConflict: 'user_id' });
        } catch (err) {
            console.warn('[ProfileUI] Could not save user preferences:', err.message);
        }
    },

    async _addToWatchlist(username) {
        // Explicit Error Boundaries to prevent silent "do nothing" failures
        if (!this._currentUser || !this._supabase) {
            this._showToast(`<i class="fa-solid fa-triangle-exclamation" style="margin-right:8px;"></i>Unable to add: Database disconnected or session expired.`, 'error');
            return;
        }
        if (!username) return;

        const alreadyTracked = this._watchlist.some(
            e => e.watched_username.toLowerCase() === username.toLowerCase()
        );
        
        if (alreadyTracked) {
            this._showToast(`<i class="fa-solid fa-circle-info" style="margin-right:8px;"></i>${username} is already on your watchlist.`, 'warn');
            return;
        }

        try {
            const { data, error } = await this._supabase
                .from('user_watchlist')
                .insert([{ user_id: this._currentUser.id, watched_username: username }])
                .select('id, watched_username, added_at')
                .single();
            
            if (error) throw error;
            
            this._watchlist.unshift(data);
            this._showToast(`<i class="fa-solid fa-star" style="margin-right:8px;"></i><strong>${username}</strong> added to watchlist.`, 'success');

            // Push the new relation to the live map so the pilot's plane
            // turns purple immediately, without waiting for the next poll.
            if (typeof window !== 'undefined' && typeof window.refreshPilotRelations === 'function') {
                window.refreshPilotRelations();
            }

            if (this._isOpen && this._activeTab === 'watchlist') this._renderContentOnly();
        } catch (err) {
            this._showToast(`<i class="fa-solid fa-circle-xmark" style="margin-right:8px;"></i>Could not add ${username}: ${err.message}`, 'error');
        }
    },

    async _removeFromWatchlist(id, username) {
        if (!this._supabase) return;
        try {
            const { error } = await this._supabase
                .from('user_watchlist')
                .delete()
                .eq('id', id);
            if (error) throw error;
            this._watchlist = this._watchlist.filter(e => e.id !== id);
            delete this._watchedPilotStatus[username?.toLowerCase()];
            this._showToast(`<i class="fa-solid fa-star-half" style="margin-right:8px;"></i>${username} removed from watchlist.`, 'info');

            // Re-tag features so the removed pilot's plane drops back to the
            // default color immediately.
            if (typeof window !== 'undefined' && typeof window.refreshPilotRelations === 'function') {
                window.refreshPilotRelations();
            }

            if (this._isOpen && this._activeTab === 'watchlist') this._renderContentOnly();
        } catch (err) {
            this._showToast(`<i class="fa-solid fa-circle-xmark" style="margin-right:8px;"></i>Could not remove pilot: ${err.message}`, 'error');
        }
    },

    _updateWatchlistDOM() {
        const container = document.getElementById('pui-watchlist-pilots-container');
        if (!container) return;
        container.innerHTML = this._getWatchlistPilotsHTML();
        container.querySelectorAll('.pui-watchlist-remove-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                this._removeFromWatchlist(e.currentTarget.dataset.id, e.currentTarget.dataset.username);
            });
        });
        // Also refresh the dock badge
        this._syncDockActiveState();
    },

    _getWatchlistTabHTML() {
        const notifChecked = this._userPrefs.notification_watchlist_enabled ? 'checked' : '';
        return `
            <div class="pui-tab-header pui-fade-in">
                <div>
                    <h2>${this.t('header.watchlist.title')}</h2>
                    <p>${this.t('header.watchlist.sub')}</p>
                </div>
                <label class="pui-toggle-label" title="Toast notification when a watched pilot goes live">
                    <input type="checkbox" id="pui-watchlist-notif-toggle" ${notifChecked}>
                    <span class="pui-toggle-track"><span class="pui-toggle-thumb"></span></span>
                    <span class="pui-toggle-text">Live alerts</span>
                </label>
            </div>

            <div class="pui-card pui-fade-in" style="margin-bottom: var(--pui-gap-md); overflow: visible; position: relative; z-index: 100;">
                <div class="pui-card-body pui-watchlist-add">
                    <div class="pui-input-wrapper pui-autocomplete-wrapper" style="flex:1; position: relative;">
                        <i class="fa-solid fa-user-plus pui-input-icon"></i>
                        <input type="text" id="pui-watchlist-input" class="pui-input has-icon" placeholder="Search active pilots or enter username…" autocomplete="off">
                        <div id="pui-watchlist-dropdown" class="pui-autocomplete-dropdown" style="display: none;"></div>
                    </div>
                    <button class="pui-btn-primary" id="pui-watchlist-add-btn">
                        <i class="fa-solid fa-plus"></i> Track pilot
                    </button>
                </div>
            </div>

            <div id="pui-watchlist-pilots-container" class="pui-fade-in">
                ${this._getWatchlistPilotsHTML()}
            </div>
        `;
    },

    _getWatchlistPilotsHTML() {
        if (this._watchlist.length === 0) {
            return `
                <div class="pui-empty-state">
                    <i class="fa-solid fa-binoculars"></i>
                    <h4>${this.t('empty.watchlist.title')}</h4>
                    <p>${this.t('empty.watchlist.body')}</p>
                </div>`;
        }
        return `
            <div class="pui-watchlist-grid">
                ${this._watchlist.map(entry => {
                    const un = entry.watched_username.toLowerCase();
                    const status = this._watchedPilotStatus[un];
                    const isLive = status?.isLive;
                    const flight = status?.flight;

                    const dep = flight?.departureIcao || '----';
                    const arr = flight?.arrivalIcao   || '----';
                    const alt = flight ? Math.round(flight.position.alt_ft).toLocaleString() + ' ft' : '—';
                    const gs  = flight ? Math.round(flight.position.gs_kt) + ' kt'                : '—';
                    const acft = flight?.aircraft?.aircraftName || '—';

                    const statusDot  = isLive
                        ? `<span class="pui-wl-dot live"></span>`
                        : `<span class="pui-wl-dot offline"></span>`;
                    const statusText = isLive ? 'Airborne' : 'Offline / On Ground';

                    return `
                        <div class="pui-wl-card ${isLive ? 'live' : ''}">
                            <div class="pui-wl-card-top">
                                <div class="pui-wl-identity">
                                    ${statusDot}
                                    <div>
                                        <div class="pui-wl-username">${entry.watched_username}</div>
                                        <div class="pui-wl-status ${isLive ? 'live' : ''}">${statusText}</div>
                                    </div>
                                </div>
                                <button class="pui-watchlist-remove-btn" data-id="${entry.id}" data-username="${entry.watched_username}" title="Remove from watchlist">
                                    <i class="fa-solid fa-xmark"></i>
                                </button>
                            </div>
                            ${isLive ? `
                            <div class="pui-wl-flight-info">
                                <div class="pui-wl-route">
                                    <span class="pui-wl-icao">${dep}</span>
                                    <i class="fa-solid fa-plane pui-wl-plane-icon"></i>
                                    <span class="pui-wl-icao">${arr}</span>
                                </div>
                                <div class="pui-wl-telemetry">
                                    <div class="pui-wl-tele-item"><span class="label">ALTITUDE</span><span class="value">${alt}</span></div>
                                    <div class="pui-wl-tele-item"><span class="label">GND SPD</span><span class="value">${gs}</span></div>
                                    <div class="pui-wl-tele-item" style="grid-column:span 2;"><span class="label">AIRCRAFT</span><span class="value" style="font-size:0.82rem;">${acft}</span></div>
                                </div>
                            </div>` : ''}
                        </div>`;
                }).join('')}
            </div>`;
    },

    _getPersonalRecordsHTML() {
        const logbook = this._ifData.logbook;
        if (!logbook || logbook.length === 0) return '';

        const longest = logbook.reduce((best, f) => (f.totalTime > (best?.totalTime || 0) ? f : best), null);
        const longestH = longest ? `${Math.floor(longest.totalTime / 60)}h ${longest.totalTime % 60}m` : '—';
        const longestRoute = longest ? `${longest.originAirport || '?'} → ${longest.destinationAirport || '?'}` : '';

        const acftCount = {};
        logbook.forEach(f => { 
            const aId = f.aircraftId || f.aircraftID;
            const lId = f.liveryId || f.liveryID;
            if (aId) {
                const name = this._resolveAircraftName(aId, lId);
                acftCount[name] = (acftCount[name] || 0) + 1; 
            }
        });
        const favAcft = Object.entries(acftCount).sort((a, b) => b[1] - a[1])[0];

        const routeCount = {};
        logbook.forEach(f => {
            if (f.originAirport && f.destinationAirport) {
                const key = `${f.originAirport} → ${f.destinationAirport}`;
                routeCount[key] = (routeCount[key] || 0) + 1;
            }
        });
        const favRoute = Object.entries(routeCount).sort((a, b) => b[1] - a[1])[0];

        const dayCount = {};
        logbook.forEach(f => {
            if (f.created) {
                const day = new Date(f.created).toISOString().slice(0, 10);
                dayCount[day] = (dayCount[day] || 0) + 1;
            }
        });
        const busiestDay = Object.entries(dayCount).sort((a, b) => b[1] - a[1])[0];

        const records = [
            { icon: 'fa-clock',          tone: 'indigo',  label: 'Longest Flight',  value: longestH,                                  sub: longestRoute },
            { icon: 'fa-plane',          tone: 'emerald', label: 'Favourite Route', value: favRoute?.[0] || '—',                       sub: favRoute ? `${favRoute[1]} times flown` : '' },
            { icon: 'fa-jet-fighter-up', tone: 'amber',   label: 'Top Aircraft',    value: favAcft?.[0] || '—',                        sub: favAcft ? `${favAcft[1]} flights` : '' },
            { icon: 'fa-calendar-day',   tone: 'rose',    label: 'Busiest Day',     value: busiestDay ? `${busiestDay[1]} flights` : '—', sub: busiestDay?.[0] || '' },
        ];

        return `
            <div class="pui-card">
                <div class="pui-card-header pui-card-header-row">
                    <h3><i class="fa-solid fa-trophy" style="color: var(--pui-accent); margin-right: 8px;"></i>Personal Records</h3>
                    <span class="pui-mono-meta-sm">from ${logbook.length.toLocaleString()} logged flights</span>
                </div>
                <div class="pui-card-body">
                    <div class="pui-records-grid">
                        ${records.map(r => `
                            <div class="pui-record" data-tone="${r.tone}">
                                <div class="pui-record-head">
                                    <span class="pui-record-icon"><i class="fa-solid ${r.icon}"></i></span>
                                    <span class="pui-record-label">${r.label}</span>
                                </div>
                                <div class="pui-record-value">${r.value}</div>
                                ${r.sub ? `<div class="pui-record-sub">${r.sub}</div>` : ''}
                            </div>`).join('')}
                    </div>
                </div>
            </div>`;
    },

    _showToast(htmlContent, type = 'info', duration = 4000) {
        const container = document.getElementById('pui-toast-container');
        if (!container) return;

        const toast = document.createElement('div');
        toast.className = `pui-toast pui-toast-${type}`;
        toast.innerHTML = htmlContent;

        const dismiss = () => {
            toast.classList.add('pui-toast-out');
            setTimeout(() => toast.remove(), 240);
        };
        toast.addEventListener('click', dismiss);
        container.appendChild(toast);
        setTimeout(dismiss, duration);
    },

    getPremiumColorExpression() {
    const activeColor = (mapFilters.iconColorMode === 'default') ? mapFilters.proCustomColor : '#ffffff';
    
    // Safely retrieve username and watchlist, falling back to empty arrays/strings
    const myIfName = (ProfileUI._currentUser && ProfileUI._currentUser.user_metadata && ProfileUI._currentUser.user_metadata.if_username) 
        ? ProfileUI._currentUser.user_metadata.if_username.toLowerCase() 
        : '';
        
    const watchlistArray = (ProfileUI._watchlist) 
        ? ProfileUI._watchlist.map(w => w.watched_username.toLowerCase()) 
        : [];

    // Mapbox requires literal arrays for 'in' expressions to not be empty
    const safeWatchlist = watchlistArray.length > 0 ? watchlistArray : ['__empty_watchlist__'];

    return [
        'case',
        // 1. User's Plane (Premium Amber/Gold)
        ['==', ['downcase', ['coalesce', ['get', 'username'], '']], myIfName], '#fbbf24',
        
        // 2. Friends/Watchlist Planes (Premium Amethyst/Purple)
        ['in', ['downcase', ['coalesce', ['get', 'username'], '']], ['literal', safeWatchlist]], '#c084fc',
        
        // 3. Traffic Highlighting or Default Color
        ['match',
            ['coalesce', ['get', 'trafficType'], 'none'],
            'inbound', '#38bdf8', 
            'outbound', '#f59e0b', 
            activeColor 
        ]
    ];
},

    /**
     * Determines the premium highlight styling for a given pilot on the map.
     * Returns a styling object if they are the user or a watched pilot, otherwise null.
     */
    getPilotHighlightInfo(username) {
        if (!username || !this._currentUser) return null;
        
        const target = username.toLowerCase();
        
        // 1. Identify Personal Aircraft -> Neon Green (HUD Match)
        const me = this._currentUser?.user_metadata?.if_username?.toLowerCase();
        if (me && target === me) {
            return {
                role: 'self',
                color: '#39ff14',
                glow: 'rgba(57, 255, 20, 0.6)',
                scale: 1.2,
                zIndex: 1000
            };
        }
        
        // 2. Identify Watchlist Pilots -> Caramel Gold (Premium Accent)
        const isWatched = this._watchlist.some(w => w.watched_username.toLowerCase() === target);
        if (isWatched) {
            return {
                role: 'watched',
                color: '#e0b384',
                glow: 'rgba(224, 179, 132, 0.6)',
                scale: 1.1,
                zIndex: 900
            };
        }
        
        return null;
    },
    

    _injectStyles() {
        if (document.getElementById('pui-dashboard-styles')) return;

        const css = `
            @import url('https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@500;700&display=swap');

            /* ═══════════════════════════════════════════════════════════════
               TOKENS — Soft premium, warm neutral foundation
               ═══════════════════════════════════════════════════════════════ */

            /* Default = LIGHT (warm parchment) */
            .pui-wrapper-layer {
                /* Surfaces */
                --pui-bg-page:        rgba(20, 17, 13, 0.42);
                --pui-bg-base:        #f5f1ea;
                --pui-bg-surface:     #faf6ef;
                --pui-bg-card:        #ffffff;
                --pui-bg-card-elev:   #fffbf3;
                --pui-bg-input:       #ffffff;
                --pui-bg-dock:        #ffffff;

                /* Text */
                --pui-text-primary:   #1a1612;
                --pui-text-secondary: #6b6258;
                --pui-text-tertiary:  #9a9088;
                --pui-text-on-accent: #fffbf3;

                /* Lines */
                --pui-border:         rgba(26, 22, 18, 0.08);
                --pui-border-light:   rgba(26, 22, 18, 0.04);
                --pui-border-strong:  rgba(26, 22, 18, 0.14);
                --pui-hover:          rgba(26, 22, 18, 0.04);

                /* Accent — warm caramel */
                --pui-accent:         #b88553;
                --pui-accent-hover:   #a87543;
                --pui-accent-soft:    rgba(184, 133, 83, 0.10);
                --pui-accent-glow:    rgba(184, 133, 83, 0.18);

                /* Semantic colours (warm-leaning) */
                --pui-pos:            #4a8c5a;
                --pui-pos-soft:       rgba(74, 140, 90, 0.12);
                --pui-neg:            #c25a5a;
                --pui-neg-soft:       rgba(194, 90, 90, 0.10);
                --pui-warn:           #c8893d;
                --pui-warn-soft:      rgba(200, 137, 61, 0.12);
                --pui-info:           #5a82c8;
                --pui-info-soft:      rgba(90, 130, 200, 0.10);
                --pui-purple:         #8c5ec8;
                --pui-purple-soft:    rgba(140, 94, 200, 0.10);

                /* Shadows */
                --pui-shadow-modal:   0 32px 64px -16px rgba(28, 22, 16, 0.28),
                                      0 0 0 1px rgba(26, 22, 18, 0.06);
                --pui-shadow-card:    0 1px 2px rgba(26, 22, 18, 0.04);
                --pui-shadow-dock:    0 12px 32px -8px rgba(28, 22, 16, 0.24),
                                      0 0 0 1px rgba(26, 22, 18, 0.06),
                                      inset 0 1px 0 rgba(255, 255, 255, 0.6);
                --pui-shadow-pop:     0 8px 24px -6px rgba(28, 22, 16, 0.18);

                /* Density (cozy default) */
                --pui-pad-card:       22px;
                --pui-pad-row:        14px;
                --pui-gap-sm:         8px;
                --pui-gap-md:         16px;
                --pui-gap-lg:         24px;
                --pui-radius-sm:      8px;
                --pui-radius:         12px;
                --pui-radius-lg:      16px;
                --pui-radius-xl:      20px;

                /* Type scale */
                --pui-font-sans:      'DM Sans', system-ui, -apple-system, sans-serif;
                --pui-font-mono:      'JetBrains Mono', ui-monospace, 'SF Mono', monospace;

                /* Motion */
                --pui-ease:           cubic-bezier(0.32, 0.72, 0, 1);
                --pui-ease-out:       cubic-bezier(0.16, 1, 0.3, 1);
                --pui-d-fast:         140ms;
                --pui-d-base:         180ms;
            }

            /* DARK (warm dark) */
            .pui-wrapper-layer[data-theme="dark"] {
                --pui-bg-page:        rgba(0, 0, 0, 0.55);
                --pui-bg-base:        #1a1612;
                --pui-bg-surface:     #221d17;
                --pui-bg-card:        #2a241d;
                --pui-bg-card-elev:   #322b22;
                --pui-bg-input:       #1f1a14;
                --pui-bg-dock:        #2a241d;

                --pui-text-primary:   #f0e9dd;
                --pui-text-secondary: #9a8e7e;
                --pui-text-tertiary:  #6e6457;
                --pui-text-on-accent: #1a1612;

                --pui-border:         rgba(255, 248, 235, 0.08);
                --pui-border-light:   rgba(255, 248, 235, 0.04);
                --pui-border-strong:  rgba(255, 248, 235, 0.14);
                --pui-hover:          rgba(255, 248, 235, 0.04);

                --pui-accent:         #d4a574;
                --pui-accent-hover:   #e0b384;
                --pui-accent-soft:    rgba(212, 165, 116, 0.14);
                --pui-accent-glow:    rgba(212, 165, 116, 0.22);

                --pui-pos:            #6db380;
                --pui-pos-soft:       rgba(109, 179, 128, 0.16);
                --pui-neg:            #d97676;
                --pui-neg-soft:       rgba(217, 118, 118, 0.14);
                --pui-warn:           #d9a563;
                --pui-warn-soft:      rgba(217, 165, 99, 0.16);
                --pui-info:           #7da0e6;
                --pui-info-soft:      rgba(125, 160, 230, 0.14);
                --pui-purple:         #b287d9;
                --pui-purple-soft:    rgba(178, 135, 217, 0.14);

                --pui-shadow-modal:   0 32px 64px -12px rgba(0, 0, 0, 0.6),
                                      0 0 0 1px rgba(255, 248, 235, 0.06);
                --pui-shadow-card:    0 1px 2px rgba(0, 0, 0, 0.2);
                --pui-shadow-dock:    0 12px 32px -8px rgba(0, 0, 0, 0.5),
                                      0 0 0 1px rgba(255, 248, 235, 0.08),
                                      inset 0 1px 0 rgba(255, 248, 235, 0.06);
                --pui-shadow-pop:     0 8px 24px -6px rgba(0, 0, 0, 0.4);
            }

            /* Compact density override */
            .pui-wrapper-layer[data-density="compact"] {
                --pui-pad-card:       16px;
                --pui-pad-row:        9px;
                --pui-gap-sm:         6px;
                --pui-gap-md:         10px;
                --pui-gap-lg:         18px;
            }

            /* ═══════════════════════════════════════════════════════════════
               KEYFRAMES — Lean, GPU-friendly only
               ═══════════════════════════════════════════════════════════════ */

            @keyframes puiFadeIn {
                from { opacity: 0; transform: translateY(6px); }
                to   { opacity: 1; transform: translateY(0); }
            }
            @keyframes puiToastIn {
                from { opacity: 0; transform: translateY(8px) scale(0.98); }
                to   { opacity: 1; transform: translateY(0) scale(1); }
            }
            @keyframes puiPulseSoft {
                0%, 100% { opacity: 0.55; }
                50%      { opacity: 0.85; }
            }
            @keyframes puiPulseDot {
                0%, 100% { transform: scale(1);   box-shadow: 0 0 0 0 var(--pui-pos-soft); }
                50%      { transform: scale(1.1); box-shadow: 0 0 0 6px transparent; }
            }

            /* ═══════════════════════════════════════════════════════════════
               OVERLAY + SHELL
               ═══════════════════════════════════════════════════════════════ */

            .pui-wrapper-layer {
                position: fixed;
                inset: 0;
                z-index: 9999;
                background: var(--pui-bg-page);
                display: flex;
                align-items: center;
                justify-content: center;
                padding: 24px;
                font-family: var(--pui-font-sans);
                opacity: 0;
                visibility: hidden;
                pointer-events: none;
                transition: opacity 240ms var(--pui-ease), visibility 0ms linear 350ms;
                color: var(--pui-text-primary);
            }
            .pui-wrapper-layer.pui-open {
                opacity: 1;
                visibility: visible;
                pointer-events: auto;
                transition: opacity 240ms var(--pui-ease), visibility 0ms linear 0ms;
            }

            .pui-shell {
                position: relative;
                width: 100%;
                max-width: 1380px;
                height: 92vh;
                background: var(--pui-bg-base);
                border-radius: var(--pui-radius-xl);
                box-shadow: var(--pui-shadow-modal);
                overflow: hidden;
                opacity: 0;
                transform: translateY(8px) scale(0.99);
                transition:
                    opacity 280ms var(--pui-ease-out) 60ms,
                    transform 280ms var(--pui-ease-out) 60ms;
            }
            .pui-wrapper-layer.pui-open .pui-shell {
                opacity: 1;
                transform: translateY(0) scale(1);
            }

            /* ═══════════════════════════════════════════════════════════════
               TOP STRIP — slim utility row floating top-right
               ═══════════════════════════════════════════════════════════════ */

            .pui-topstrip {
                position: absolute;
                top: 0;
                left: 0;
                right: 0;
                height: 60px;
                padding: 0 24px;
                display: flex;
                align-items: center;
                justify-content: space-between;
                z-index: 50;
                pointer-events: none;
            }
            .pui-topstrip-left, .pui-topstrip-right {
                display: flex;
                align-items: center;
                gap: 8px;
                pointer-events: auto;
            }

            .pui-brand {
                display: flex;
                align-items: center;
                height: 100%;
            }
            .pui-brand-logo {
                max-height: 40px;
                width: auto;
                object-fit: contain;
                user-select: none;
                -webkit-user-drag: none;
                transition: opacity var(--pui-d-fast) var(--pui-ease);
            }
            .pui-brand-logo:hover {
                opacity: 0.85;
            }

            .pui-icon-btn {
                width: 36px;
                height: 36px;
                border-radius: 10px;
                background: var(--pui-bg-card);
                border: 1px solid var(--pui-border);
                color: var(--pui-text-secondary);
                font-size: 0.85rem;
                cursor: pointer;
                display: grid;
                place-items: center;
                transition:
                    background-color var(--pui-d-fast) var(--pui-ease),
                    color var(--pui-d-fast) var(--pui-ease),
                    border-color var(--pui-d-fast) var(--pui-ease),
                    transform var(--pui-d-fast) var(--pui-ease);
            }
            .pui-icon-btn:hover {
                background: var(--pui-bg-card-elev);
                color: var(--pui-text-primary);
                border-color: var(--pui-border-strong);
            }
            .pui-icon-btn:active { transform: translateY(1px); }
            .pui-icon-btn-close:hover {
                background: var(--pui-neg-soft);
                color: var(--pui-neg);
                border-color: transparent;
            }

            .pui-user-chip {
                display: flex;
                align-items: center;
                gap: 10px;
                padding: 4px 12px 4px 4px;
                background: var(--pui-bg-card);
                border: 1px solid var(--pui-border);
                border-radius: 999px;
                height: 36px;
                user-select: none;
            }
            .pui-user-initials {
                width: 28px;
                height: 28px;
                border-radius: 50%;
                background: var(--pui-accent);
                color: var(--pui-text-on-accent);
                font-weight: 700;
                font-size: 0.72rem;
                letter-spacing: 0.02em;
                display: grid;
                place-items: center;
            }
            .pui-user-meta {
                display: flex;
                flex-direction: column;
                line-height: 1.1;
                gap: 1px;
            }
            .pui-user-name {
                font-size: 0.78rem;
                font-weight: 600;
                color: var(--pui-text-primary);
            }
            .pui-user-plan {
                font-size: 0.62rem;
                font-weight: 600;
                color: var(--pui-accent);
                text-transform: uppercase;
                letter-spacing: 0.06em;
            }

            /* ═══════════════════════════════════════════════════════════════
               CONTENT — scrollable, padded to clear the dock
               ═══════════════════════════════════════════════════════════════ */

            .pui-content {
                position: absolute;
                inset: 60px 0 0 0;
                padding: 24px 40px 130px;
                overflow-y: auto;
                overflow-x: hidden;
                scrollbar-width: thin;
                scrollbar-color: var(--pui-border) transparent;
            }
            .pui-content::-webkit-scrollbar { width: 8px; }
            .pui-content::-webkit-scrollbar-track { background: transparent; }
            .pui-content::-webkit-scrollbar-thumb {
                background: var(--pui-border);
                border-radius: 4px;
            }

            .pui-wrapper-layer[data-density="compact"] .pui-content {
                padding: 18px 28px 120px;
            }

            /* Onboarding hides chrome and uses full-bleed */
            [data-active-tab="onboarding"] .pui-content {
                inset: 0;
                padding: 0;
                background: radial-gradient(ellipse at top, var(--pui-bg-card-elev), var(--pui-bg-base) 60%);
                display: flex;
                align-items: center;
                justify-content: center;
            }

            /* ═══════════════════════════════════════════════════════════════
               DOCK — floating bottom-center pill
               ═══════════════════════════════════════════════════════════════ */

            .pui-dock {
                position: absolute;
                bottom: 22px;
                left: 50%;
                transform: translateX(-50%);
                z-index: 60;
                pointer-events: auto;
            }
            .pui-dock-inner {
                display: flex;
                gap: 4px;
                background: var(--pui-bg-dock);
                border-radius: 18px;
                padding: 6px;
                box-shadow: var(--pui-shadow-dock);
            }
            .pui-dock-item {
                position: relative;
                background: transparent;
                border: none;
                color: var(--pui-text-secondary);
                font-family: var(--pui-font-sans);
                font-size: 0.78rem;
                font-weight: 600;
                letter-spacing: 0.01em;
                padding: 9px 14px;
                border-radius: 12px;
                cursor: pointer;
                display: flex;
                align-items: center;
                gap: 9px;
                white-space: nowrap;
                transition:
                    background-color var(--pui-d-base) var(--pui-ease),
                    color var(--pui-d-base) var(--pui-ease),
                    transform var(--pui-d-fast) var(--pui-ease);
            }
            .pui-dock-icon {
                width: 18px;
                display: grid;
                place-items: center;
                font-size: 0.95rem;
                line-height: 1;
            }
            .pui-dock-label {
                line-height: 1;
            }
            .pui-dock-item:hover {
                background: var(--pui-hover);
                color: var(--pui-text-primary);
            }
            .pui-dock-item:active { transform: translateY(1px); }
            .pui-dock-item.active {
                background: var(--pui-accent-soft);
                color: var(--pui-accent);
            }
            .pui-dock-item.active .pui-dock-icon {
                color: var(--pui-accent);
            }
            .pui-dock-badge {
                position: absolute;
                top: 2px;
                right: 4px;
                min-width: 16px;
                height: 16px;
                padding: 0 5px;
                background: var(--pui-pos);
                color: #fff;
                font-size: 0.6rem;
                font-weight: 800;
                border-radius: 999px;
                display: grid;
                place-items: center;
                line-height: 1;
                box-shadow: 0 0 0 2px var(--pui-bg-dock);
            }

            /* ═══════════════════════════════════════════════════════════════
               TYPOGRAPHY HELPERS
               ═══════════════════════════════════════════════════════════════ */

            .pui-mono { font-family: var(--pui-font-mono); }
            .pui-mono-h {
                font-family: var(--pui-font-mono);
                font-size: 1.25rem;
                font-weight: 700;
                margin: 0;
                letter-spacing: 0.04em;
                color: var(--pui-text-primary);
            }
            .pui-eyebrow {
                font-size: 0.66rem;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.1em;
                color: var(--pui-text-secondary);
            }
            .pui-mono-meta {
                font-family: var(--pui-font-mono);
                font-size: 0.74rem;
                color: var(--pui-text-secondary);
                font-weight: 600;
            }
            .pui-mono-meta-sm {
                font-family: var(--pui-font-mono);
                font-size: 0.66rem;
                color: var(--pui-text-tertiary);
                font-weight: 600;
            }

            /* ═══════════════════════════════════════════════════════════════
               TAB HEADER
               ═══════════════════════════════════════════════════════════════ */

            .pui-tab-header {
                display: flex;
                justify-content: space-between;
                align-items: flex-end;
                gap: var(--pui-gap-md);
                flex-wrap: wrap;
                margin-bottom: var(--pui-gap-lg);
            }
            .pui-tab-header h2 {
                margin: 0 0 4px 0;
                font-size: 1.5rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                letter-spacing: -0.02em;
            }
            .pui-tab-header p {
                margin: 0;
                color: var(--pui-text-secondary);
                font-size: 0.88rem;
                line-height: 1.45;
            }
            .pui-tab-header-actions {
                display: flex;
                gap: 10px;
                align-items: stretch;
            }

            /* ═══════════════════════════════════════════════════════════════
               CARD
               ═══════════════════════════════════════════════════════════════ */

            .pui-card {
                background: var(--pui-bg-card);
                border: 1px solid var(--pui-border);
                border-radius: var(--pui-radius-lg);
                box-shadow: var(--pui-shadow-card);
                overflow: hidden;
            }
            .pui-card-header {
                padding: 16px var(--pui-pad-card);
                border-bottom: 1px solid var(--pui-border-light);
            }
            .pui-card-header h3 {
                margin: 0;
                font-size: 0.92rem;
                font-weight: 600;
                color: var(--pui-text-primary);
                letter-spacing: -0.005em;
            }
            .pui-card-header-row {
                display: flex;
                align-items: center;
                justify-content: space-between;
            }
            .pui-card-title-group {
                display: flex;
                align-items: center;
                gap: 10px;
            }
            .pui-card-body { padding: var(--pui-pad-card); }
            .pui-card-eyebrow {
                font-size: 0.62rem;
                font-weight: 700;
                letter-spacing: 0.12em;
                text-transform: uppercase;
                color: var(--pui-text-tertiary);
                margin-bottom: 14px;
            }
            .pui-card-footer {
                margin-top: var(--pui-gap-md);
                padding-top: var(--pui-gap-md);
                border-top: 1px solid var(--pui-border-light);
                display: flex;
                justify-content: flex-end;
            }

            .pui-grid-cards {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(360px, 1fr));
                gap: var(--pui-gap-md);
            }

            /* ═══════════════════════════════════════════════════════════════
               BUTTONS
               ═══════════════════════════════════════════════════════════════ */

            .pui-btn-primary {
                background: var(--pui-accent);
                color: var(--pui-text-on-accent);
                border: 1px solid transparent;
                border-radius: 10px;
                padding: 10px 18px;
                font-size: 0.86rem;
                font-weight: 600;
                font-family: var(--pui-font-sans);
                cursor: pointer;
                display: inline-flex;
                align-items: center;
                justify-content: center;
                gap: 8px;
                transition:
                    background-color var(--pui-d-fast) var(--pui-ease),
                    transform var(--pui-d-fast) var(--pui-ease),
                    box-shadow var(--pui-d-fast) var(--pui-ease);
                box-shadow: 0 1px 2px rgba(0,0,0,0.04);
            }
            .pui-btn-primary:hover {
                background: var(--pui-accent-hover);
                box-shadow: 0 4px 12px var(--pui-accent-glow);
            }
            .pui-btn-primary:active { transform: translateY(1px); }
            .pui-btn-primary:disabled { opacity: 0.55; cursor: not-allowed; }
            .pui-btn-block { width: 100%; padding: 12px 20px; }

            .pui-btn-secondary {
                background: var(--pui-bg-card);
                color: var(--pui-text-primary);
                border: 1px solid var(--pui-border);
                border-radius: 10px;
                padding: 10px 18px;
                font-size: 0.86rem;
                font-weight: 600;
                font-family: var(--pui-font-sans);
                cursor: pointer;
                display: inline-flex;
                align-items: center;
                justify-content: center;
                gap: 8px;
                width: 100%;
                transition:
                    background-color var(--pui-d-fast) var(--pui-ease),
                    border-color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-btn-secondary:hover {
                background: var(--pui-bg-card-elev);
                border-color: var(--pui-border-strong);
            }
            .pui-btn-ghost {
                background: transparent;
                border: 1px solid var(--pui-border);
                color: var(--pui-text-secondary);
                font-family: var(--pui-font-sans);
                font-size: 0.78rem;
                font-weight: 600;
                padding: 7px 14px;
                border-radius: 9px;
                cursor: pointer;
                display: inline-flex;
                align-items: center;
                gap: 6px;
                transition:
                    background-color var(--pui-d-fast) var(--pui-ease),
                    color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-btn-ghost:hover {
                background: var(--pui-hover);
                color: var(--pui-text-primary);
            }
            .pui-btn-danger-outline {
                background: transparent;
                color: var(--pui-neg);
                border: 1px solid var(--pui-neg-soft);
                border-radius: 10px;
                padding: 10px 18px;
                font-size: 0.85rem;
                font-weight: 600;
                font-family: var(--pui-font-sans);
                cursor: pointer;
                display: inline-flex;
                align-items: center;
                justify-content: center;
                gap: 8px;
                width: 100%;
                transition:
                    background-color var(--pui-d-fast) var(--pui-ease),
                    border-color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-btn-danger-outline:hover {
                background: var(--pui-neg-soft);
                border-color: var(--pui-neg);
            }

            /* ═══════════════════════════════════════════════════════════════
               INPUTS & AUTOCOMPLETE
               ═══════════════════════════════════════════════════════════════ */

            .pui-input-group { margin-bottom: var(--pui-gap-md); }
            .pui-input-group label {
                display: block;
                font-size: 0.72rem;
                font-weight: 600;
                color: var(--pui-text-secondary);
                margin-bottom: 6px;
                letter-spacing: 0.02em;
            }
            .pui-input-wrapper {
                position: relative;
                display: flex;
                align-items: center;
            }
            .pui-input-icon {
                position: absolute;
                left: 12px;
                color: var(--pui-text-tertiary);
                font-size: 0.82rem;
                pointer-events: none;
            }
            .pui-input {
                width: 100%;
                padding: 10px 12px;
                border: 1px solid var(--pui-border);
                border-radius: 10px;
                background: var(--pui-bg-input);
                color: var(--pui-text-primary);
                font-size: 0.88rem;
                font-family: var(--pui-font-sans);
                transition:
                    border-color var(--pui-d-fast) var(--pui-ease),
                    box-shadow var(--pui-d-fast) var(--pui-ease);
            }
            .pui-input.has-icon { padding-left: 36px; }
            .pui-input:focus {
                outline: none;
                border-color: var(--pui-accent);
                box-shadow: 0 0 0 3px var(--pui-accent-soft);
            }
            .pui-input:disabled {
                opacity: 0.5;
                cursor: not-allowed;
            }
            .pui-icao-input {
                font-family: var(--pui-font-mono);
                text-transform: uppercase;
                font-weight: 700;
                letter-spacing: 0.05em;
            }
            .pui-help-text {
                margin: 6px 0 0 0;
                font-size: 0.72rem;
                color: var(--pui-text-tertiary);
                line-height: 1.4;
            }
            .pui-select {
                appearance: none;
                cursor: pointer;
                padding-right: 36px;
            }
            .pui-select-chevron {
                position: absolute;
                right: 12px;
                color: var(--pui-text-tertiary);
                pointer-events: none;
                font-size: 0.72rem;
            }
            .pui-form-row {
                display: flex;
                gap: 12px;
                margin-bottom: 12px;
            }
            .pui-form-row .pui-input-group { flex: 1; margin-bottom: 0; }
            .pui-form-section { margin-bottom: var(--pui-gap-lg); }
            .pui-form-section-title {
                margin: 0 0 12px 0;
                font-size: 0.66rem;
                font-weight: 700;
                color: var(--pui-text-tertiary);
                text-transform: uppercase;
                letter-spacing: 0.1em;
                padding-bottom: 6px;
                border-bottom: 1px solid var(--pui-border-light);
            }
            .pui-form-actions {
                margin-top: var(--pui-gap-lg);
                padding-top: var(--pui-gap-md);
                border-top: 1px solid var(--pui-border-light);
                display: flex;
                justify-content: flex-end;
            }

            /* Autocomplete */
            .pui-autocomplete-dropdown {
                position: absolute;
                top: calc(100% + 8px);
                left: 0;
                right: 0;
                background: var(--pui-bg-card-elev);
                border: 1px solid var(--pui-border-strong);
                border-radius: 12px;
                box-shadow: var(--pui-shadow-pop);
                z-index: 100;
                overflow: hidden;
                max-height: 280px;
                overflow-y: auto;
                animation: puiFadeIn var(--pui-d-fast) var(--pui-ease-out);
            }
            .pui-autocomplete-item {
                display: flex;
                align-items: center;
                gap: 12px;
                padding: 10px 14px;
                cursor: pointer;
                transition: background-color var(--pui-d-fast) var(--pui-ease);
                border-bottom: 1px solid var(--pui-border-light);
            }
            .pui-autocomplete-item:last-child { border-bottom: none; }
            .pui-autocomplete-item:hover { background: var(--pui-hover); }
            .pui-ac-icon {
                width: 32px;
                height: 32px;
                border-radius: 8px;
                background: var(--pui-accent-soft);
                color: var(--pui-accent);
                display: grid;
                place-items: center;
                font-size: 0.85rem;
                flex-shrink: 0;
            }
            .pui-ac-details {
                display: flex;
                flex-direction: column;
                gap: 2px;
            }
            .pui-ac-name {
                font-size: 0.88rem;
                font-weight: 700;
                color: var(--pui-text-primary);
            }
            .pui-ac-meta {
                font-family: var(--pui-font-mono);
                font-size: 0.68rem;
                color: var(--pui-text-secondary);
                font-weight: 600;
            }

            /* ═══════════════════════════════════════════════════════════════
               ALERTS, BADGES, TAGS
               ═══════════════════════════════════════════════════════════════ */

            .pui-alert {
                padding: 11px 14px;
                border-radius: 10px;
                font-size: 0.84rem;
                font-weight: 500;
                margin-top: 12px;
                display: flex;
                align-items: center;
                gap: 8px;
            }
            .pui-alert-success { background: var(--pui-pos-soft); color: var(--pui-pos); }
            .pui-alert-error   { background: var(--pui-neg-soft); color: var(--pui-neg); }
            .pui-alert-info    { background: var(--pui-info-soft); color: var(--pui-info); }
            .pui-alert-warn    { background: var(--pui-warn-soft); color: var(--pui-warn); }

            .pui-status-badge {
                padding: 3px 10px;
                border-radius: 999px;
                font-size: 0.66rem;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.06em;
            }
            .pui-status-badge.pos { background: var(--pui-pos-soft); color: var(--pui-pos); }
            .pui-status-badge.neg { background: var(--pui-neg-soft); color: var(--pui-neg); }

            .pui-mini-tag {
                display: inline-flex;
                align-items: center;
                gap: 5px;
                padding: 3px 8px;
                border-radius: 6px;
                font-size: 0.62rem;
                font-weight: 700;
                letter-spacing: 0.04em;
            }
            .pui-mini-tag-row {
                display: flex;
                flex-wrap: wrap;
                gap: 6px;
                margin-bottom: var(--pui-gap-md);
            }
            .pui-chip-soft {
                display: inline-block;
                padding: 3px 8px;
                background: var(--pui-hover);
                border-radius: 6px;
                font-size: 0.7rem;
                color: var(--pui-text-secondary);
            }
            .pui-chip-soft em {
                font-style: normal;
                color: var(--pui-text-tertiary);
                font-size: 0.65rem;
            }

            /* ═══════════════════════════════════════════════════════════════
               STATS GRID + STAT CARDS
               ═══════════════════════════════════════════════════════════════ */

            .pui-stats-grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                gap: var(--pui-gap-md);
            }
            .pui-stat-card {
                background: var(--pui-bg-card);
                border: 1px solid var(--pui-border);
                border-radius: var(--pui-radius-lg);
                padding: 16px 18px;
                display: flex;
                align-items: center;
                gap: 14px;
                box-shadow: var(--pui-shadow-card);
                transition: border-color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-stat-card:hover { border-color: var(--pui-border-strong); }
            .pui-stat-icon {
                width: 44px;
                height: 44px;
                border-radius: 12px;
                display: grid;
                place-items: center;
                font-size: 1.1rem;
                flex-shrink: 0;
            }
            .pui-stat-icon[data-tone="indigo"]  { background: rgba(99,102,241,0.10);  color: #6366f1; }
            .pui-stat-icon[data-tone="violet"]  { background: rgba(139,92,246,0.10);  color: #8b5cf6; }
            .pui-stat-icon[data-tone="emerald"] { background: rgba(16,185,129,0.10);  color: #10b981; }
            .pui-stat-icon[data-tone="amber"]   { background: rgba(245,158,11,0.10);  color: #f59e0b; }
            .pui-stat-icon[data-tone="rose"]    { background: rgba(244,63,94,0.10);   color: #f43f5e; }
            .pui-wrapper-layer[data-theme="dark"] .pui-stat-icon[data-tone="indigo"]  { background: rgba(129,140,248,0.16); color: #818cf8; }
            .pui-wrapper-layer[data-theme="dark"] .pui-stat-icon[data-tone="violet"]  { background: rgba(167,139,250,0.16); color: #a78bfa; }
            .pui-wrapper-layer[data-theme="dark"] .pui-stat-icon[data-tone="emerald"] { background: rgba(52,211,153,0.16);  color: #34d399; }
            .pui-wrapper-layer[data-theme="dark"] .pui-stat-icon[data-tone="amber"]   { background: rgba(251,191,36,0.16);  color: #fbbf24; }
            .pui-wrapper-layer[data-theme="dark"] .pui-stat-icon[data-tone="rose"]    { background: rgba(251,113,133,0.16); color: #fb7185; }
            .pui-stat-data h3 {
                margin: 0 0 2px 0;
                font-size: 1.2rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                letter-spacing: -0.01em;
            }
            .pui-stat-data p {
                margin: 0;
                color: var(--pui-text-secondary);
                font-size: 0.76rem;
                font-weight: 500;
            }

            /* ═══════════════════════════════════════════════════════════════
               HOME / DASHBOARD
               ═══════════════════════════════════════════════════════════════ */

            .pui-home-header {
                display: flex;
                justify-content: space-between;
                align-items: flex-end;
                gap: var(--pui-gap-md);
                margin-bottom: var(--pui-gap-lg);
                padding-bottom: var(--pui-gap-md);
                border-bottom: 1px solid var(--pui-border);
                flex-wrap: wrap;
            }
            .pui-home-greeting {
                margin: 0 0 6px 0;
                font-size: 1.85rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                letter-spacing: -0.025em;
                line-height: 1.1;
            }
            .pui-home-date {
                font-size: 0.78rem;
                color: var(--pui-text-tertiary);
                font-weight: 500;
                white-space: nowrap;
            }
            .pui-stat-strip {
                display: flex;
                align-items: center;
                gap: 8px;
                flex-wrap: wrap;
                color: var(--pui-text-secondary);
                font-size: 0.8rem;
                font-weight: 500;
            }
            .pui-strip-sep { opacity: 0.4; }
            .pui-strip-stale {
                color: var(--pui-warn);
                font-size: 0.7rem;
                display: inline-flex;
                align-items: center;
                gap: 4px;
            }

            .pui-home-grid {
                display: grid;
                grid-template-columns: 1fr 320px;
                gap: var(--pui-gap-md);
            }
            .pui-home-recent, .pui-home-dispatch {
                padding: 20px var(--pui-pad-card);
                display: flex;
                flex-direction: column;
            }
            .pui-wrapper-layer[data-density="compact"] .pui-home-recent,
            .pui-wrapper-layer[data-density="compact"] .pui-home-dispatch {
                padding: 14px var(--pui-pad-card);
            }

            /* ═══════════════════════════════════════════════════════════════
               FLIGHT ROWS (recent flights list)
               ═══════════════════════════════════════════════════════════════ */

            .pui-flight-list {
                display: flex;
                flex-direction: column;
            }
            .pui-flight-row {
                display: flex;
                align-items: center;
                gap: 12px;
                padding: var(--pui-pad-row) 0;
                border-bottom: 1px solid var(--pui-border-light);
                transition: background-color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-flight-row:last-child { border-bottom: none; }
            .pui-flight-row:hover {
                background: var(--pui-hover);
                margin: 0 calc(var(--pui-pad-card) * -1);
                padding-left: var(--pui-pad-card);
                padding-right: var(--pui-pad-card);
                border-radius: 6px;
            }
            .pui-flight-route {
                display: flex;
                align-items: center;
                gap: 8px;
                flex: 1;
                min-width: 0;
            }
            .pui-flight-icao {
                font-family: var(--pui-font-mono);
                font-size: 0.86rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                letter-spacing: 0.02em;
            }
            .pui-flight-arrow {
                color: var(--pui-text-tertiary);
                font-size: 0.7rem;
            }
            .pui-flight-meta {
                display: flex;
                align-items: center;
                gap: 5px;
                font-size: 0.7rem;
                color: var(--pui-text-secondary);
                font-weight: 500;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }
            .pui-flight-time {
                font-size: 0.68rem;
                color: var(--pui-text-tertiary);
                font-weight: 600;
                white-space: nowrap;
                flex-shrink: 0;
            }
            .pui-empty-inline {
                color: var(--pui-text-tertiary);
                font-size: 0.82rem;
                text-align: center;
                padding: 24px 8px;
            }

            .pui-empty-inline {
                color: var(--pui-text-tertiary);
                font-size: 0.82rem;
                text-align: center;
                padding: 24px 8px;
            }

            .pui-plan-quick-btn {
                margin-left: 8px;
                width: 28px;
                height: 28px;
                font-size: 0.75rem;
                color: var(--pui-accent);
                border-color: transparent;
                background: var(--pui-accent-soft);
                opacity: 0;
                transform: translateX(-4px);
                transition: all var(--pui-d-fast) var(--pui-ease) !important;
            }
            .pui-flight-row:hover .pui-plan-quick-btn {
                opacity: 1;
                transform: translateX(0);
            }
            .pui-plan-quick-btn:hover {
                background: var(--pui-accent);
                color: var(--pui-text-on-accent);
                transform: scale(1.05) !important;
            }

            /* ═══════════════════════════════════════════════════════════════
               LIVE FLIGHT CAROUSEL — cleaner overlay, no fullscreen blur
               ═══════════════════════════════════════════════════════════════ */

            .pui-live-carousel {
                display: flex;
                gap: 16px;
                overflow-x: auto;
                scroll-snap-type: x mandatory;
                margin-bottom: var(--pui-gap-md);
                scrollbar-width: none;
            }
            .pui-live-carousel::-webkit-scrollbar { display: none; }

            .pui-live-card {
                position: relative;
                flex: 0 0 calc(100% - 6px);
                max-width: 820px;
                min-height: 320px;
                height: auto;
                border-radius: var(--pui-radius-xl);
                overflow: hidden;
                scroll-snap-align: center;
                box-shadow: var(--pui-shadow-pop);
                display: flex;
                flex-direction: column;
            }

            .pui-live-gate {
                font-size: 0.65rem;
                font-weight: 700;
                letter-spacing: 0.05em;
                color: rgba(255, 255, 255, 0.65);
                margin: 0 4px;
            }
            .pui-live-dispatch-strip {
                display: flex;
                align-items: center;
                gap: 14px;
                margin-top: 12px;
                padding: 10px 16px;
                background: rgba(184, 133, 83, 0.15);
                border: 1px solid rgba(184, 133, 83, 0.25);
                border-radius: 12px;
                flex-wrap: wrap;
                backdrop-filter: blur(4px);
            }
            .pui-live-dispatch-tag {
                font-size: 0.65rem;
                font-weight: 800;
                letter-spacing: 0.12em;
                color: #e0b384;
                display: flex;
                align-items: center;
                gap: 6px;
                margin-right: auto;
            }
            .pui-live-dispatch-item {
                font-size: 0.78rem;
                color: rgba(255, 255, 255, 0.95);
                font-weight: 600;
                display: flex;
                align-items: center;
                gap: 6px;
                font-family: var(--pui-font-mono);
            }
            .pui-live-dispatch-item i {
                color: rgba(255, 255, 255, 0.5);
                font-size: 0.75rem;
            }
            .pui-live-bg {
                position: absolute;
                inset: 0;
                background-size: cover;
                background-position: center;
                z-index: 1;
            }
            .pui-live-bg-fallback {
                background: linear-gradient(135deg, #2a3445 0%, #1a2030 60%, #14181f 100%);
            }
            /* 3D forward-view backdrop (CesiumJS). The viewer is mounted into
               this slot in place of the static image background for the user's
               primary live flight. The dark fill is what shows during the
               brief tile/imagery boot before Cesium starts rendering. */
            .pui-live-bg-3d {
                background: #0a1628;
                overflow: hidden;
            }
            .pui-live-bg-3d > * {
                width: 100%;
                height: 100%;
            }
            .pui-live-overlay {
                position: absolute;
                inset: 0;
                background: linear-gradient(to top,
                    rgba(15, 12, 8, 0.92) 0%,
                    rgba(15, 12, 8, 0.4) 35%,
                    rgba(15, 12, 8, 0.1) 75%,
                    transparent 100%);
                z-index: 2;
                pointer-events: none;
            }
            .pui-live-content {
                position: relative;
                z-index: 3;
                height: 100%;
                display: flex;
                flex-direction: column;
                padding: 20px 22px;
                color: #fff;
            }
            .pui-live-top {
                display: flex;
                justify-content: space-between;
                align-items: flex-start;
            }
            .pui-live-route-pill {
                display: inline-flex;
                align-items: center;
                gap: 10px;
                padding: 6px 12px;
                background: rgba(0, 0, 0, 0.5);
                border: 1px solid rgba(255, 255, 255, 0.1);
                border-radius: 999px;
            }
            .pui-live-icao {
                font-family: var(--pui-font-mono);
                font-size: 0.92rem;
                font-weight: 700;
                color: #fff;
                letter-spacing: 0.04em;
            }
            .pui-live-route-icon {
                color: #fff;
                font-size: 0.7rem;
                opacity: 0.7;
            }
            .pui-live-ident {
                display: flex;
                flex-direction: column;
                align-items: flex-end;
                text-align: right;
            }
            .pui-live-acft {
                font-size: 0.92rem;
                font-weight: 700;
                color: #fff;
                text-shadow: 0 1px 4px rgba(0, 0, 0, 0.6);
            }
            .pui-live-cs {
                font-family: var(--pui-font-mono);
                font-size: 0.74rem;
                color: rgba(255, 255, 255, 0.85);
                font-weight: 600;
                margin-top: 2px;
                text-shadow: 0 1px 4px rgba(0, 0, 0, 0.6);
            }
            .pui-live-spacer { flex: 1; }
            .pui-live-stats {
                display: grid;
                grid-template-columns: repeat(4, 1fr);
                background: rgba(255, 255, 255, 0.04);
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 12px;
                overflow: hidden;
            }
            .pui-live-stat {
                display: flex;
                flex-direction: column;
                gap: 2px;
                padding: 10px 14px;
                border-right: 1px solid rgba(255, 255, 255, 0.06);
            }
            .pui-live-stat:last-child { border-right: none; }
            .pui-live-stat .label {
                font-size: 0.56rem;
                font-weight: 700;
                letter-spacing: 0.1em;
                text-transform: uppercase;
                color: rgba(255, 255, 255, 0.55);
            }
            .pui-live-stat .value {
                font-family: var(--pui-font-mono);
                font-size: 1.05rem;
                font-weight: 700;
                color: #fff;
                line-height: 1;
                display: flex;
                align-items: baseline;
                gap: 3px;
            }
            .pui-live-stat .value em {
                font-style: normal;
                font-size: 0.62rem;
                color: rgba(255, 255, 255, 0.5);
                font-weight: 600;
            }
            .pui-live-credit {
                position: absolute;
                bottom: 8px;
                right: 14px;
                font-size: 0.56rem;
                color: rgba(255, 255, 255, 0.5);
                font-weight: 500;
                pointer-events: none;
            }

            /* ═══════════════════════════════════════════════════════════════
               DISPATCH (next departure on home)
               ═══════════════════════════════════════════════════════════════ */

            .pui-dispatch-route {
                display: flex;
                align-items: center;
                gap: 10px;
                padding: 12px 0 14px;
                border-bottom: 1px solid var(--pui-border-light);
                margin-bottom: 14px;
            }
            .pui-dispatch-side {
                display: flex;
                flex-direction: column;
                gap: 4px;
            }
            .pui-dispatch-side-right { text-align: right; align-items: flex-end; }
            .pui-dispatch-side .code {
                font-family: var(--pui-font-mono);
                font-size: 1.6rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                letter-spacing: -0.02em;
                line-height: 1;
            }
            .pui-dispatch-side .gate {
                font-size: 0.65rem;
                color: var(--pui-text-tertiary);
                font-weight: 600;
            }
            .pui-dispatch-path {
                flex: 1;
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 4px;
                color: var(--pui-text-tertiary);
                font-size: 0.66rem;
                font-weight: 600;
            }
            .pui-dispatch-path i {
                color: var(--pui-accent);
                font-size: 0.85rem;
            }
            .pui-dispatch-info {
                display: flex;
                flex-direction: column;
                gap: 9px;
            }
            .pui-dispatch-row {
                display: flex;
                justify-content: space-between;
                align-items: center;
                font-size: 0.8rem;
            }
            .pui-dispatch-row span {
                color: var(--pui-text-secondary);
                font-weight: 500;
            }
            .pui-dispatch-row strong {
                color: var(--pui-text-primary);
                font-weight: 700;
            }
            .pui-empty-block {
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                gap: 10px;
                padding: 32px 0;
                color: var(--pui-text-tertiary);
                font-size: 0.82rem;
                text-align: center;
            }
            .pui-empty-block i {
                font-size: 1.6rem;
                opacity: 0.4;
            }

            /* ═══════════════════════════════════════════════════════════════
               FLIGHT TICKETS (Dispatch tab)
               ═══════════════════════════════════════════════════════════════ */

            .pui-dispatch-layout {
                display: grid;
                grid-template-columns: 1fr 400px;
                gap: var(--pui-gap-lg);
                align-items: start;
            }
            .pui-dispatch-list {
                display: flex;
                flex-direction: column;
                gap: var(--pui-gap-md);
            }
            .pui-ticket {
                position: relative;
                background: var(--pui-bg-card);
                border: 1px solid var(--pui-border);
                border-radius: var(--pui-radius-lg);
                box-shadow: var(--pui-shadow-card);
                display: flex;
                overflow: hidden;
                transition:
                    border-color var(--pui-d-fast) var(--pui-ease),
                    box-shadow var(--pui-d-fast) var(--pui-ease);
            }
            .pui-ticket:hover {
                border-color: var(--pui-border-strong);
                box-shadow: var(--pui-shadow-pop);
            }
 .pui-ticket-actions {
                position: absolute;
                top: 12px;
                right: 12px;
                display: flex;
                gap: 6px;
                opacity: 0;
                pointer-events: none;
                z-index: 10;
                transition: opacity var(--pui-d-fast) var(--pui-ease);
            }
            .pui-ticket:hover .pui-ticket-actions {
                opacity: 1;
                pointer-events: auto;
            }
            .pui-ticket-stub {
                background: var(--pui-bg-surface);
                padding: 18px 20px;
                display: flex;
                flex-direction: column;
                justify-content: center;
                gap: 4px;
                border-right: 1px dashed var(--pui-border);
                min-width: 130px;
            }
            .pui-ticket-day {
                font-size: 0.62rem;
                font-weight: 700;
                color: var(--pui-text-tertiary);
                text-transform: uppercase;
                letter-spacing: 0.1em;
            }
            .pui-ticket-date {
                font-family: var(--pui-font-mono);
                font-size: 0.86rem;
                font-weight: 700;
                color: var(--pui-text-primary);
            }
            .pui-ticket-time {
                font-size: 0.74rem;
                color: var(--pui-text-secondary);
                font-weight: 600;
            }
            .pui-ticket-cs {
                margin-top: 6px;
                display: inline-block;
                background: var(--pui-accent-soft);
                color: var(--pui-accent);
                padding: 3px 8px;
                border-radius: 6px;
                font-size: 0.74rem;
                font-weight: 700;
                font-family: var(--pui-font-mono);
                width: fit-content;
            }
            .pui-ticket-body {
                flex: 1;
                padding: 18px 20px;
                display: flex;
                align-items: center;
            }
            .pui-ticket-route {
                width: 100%;
                display: flex;
                align-items: center;
                justify-content: space-between;
                gap: 16px;
            }
            .pui-ticket-point {
                display: flex;
                flex-direction: column;
                gap: 4px;
            }
            .pui-ticket-point-right { align-items: flex-end; }
            .pui-ticket-icao {
                font-family: var(--pui-font-mono);
                font-size: 1.5rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                letter-spacing: -0.01em;
                line-height: 1;
            }
            .pui-ticket-gate {
                font-size: 0.66rem;
                color: var(--pui-text-tertiary);
                font-weight: 600;
            }
            .pui-ticket-path {
                flex: 1;
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 6px;
                position: relative;
                padding: 0 16px;
            }
            .pui-ticket-duration {
                font-size: 0.68rem;
                color: var(--pui-text-tertiary);
                font-weight: 600;
            }
            .pui-ticket-line {
                width: 100%;
                height: 1px;
                background: var(--pui-border);
                position: relative;
                display: flex;
                justify-content: center;
                align-items: center;
            }
            .pui-ticket-line i {
                position: absolute;
                color: var(--pui-accent);
                font-size: 0.85rem;
                background: var(--pui-bg-card);
                padding: 0 6px;
            }
            .pui-ticket-acft {
                font-size: 0.7rem;
                color: var(--pui-text-secondary);
                font-weight: 700;
                letter-spacing: 0.04em;
            }
            .pui-ticket-aside {
                padding: 18px 20px;
                display: flex;
                flex-direction: column;
                gap: 8px;
                justify-content: center;
                border-left: 1px solid var(--pui-border-light);
                min-width: 130px;
            }
            .pui-ticket-stat {
                display: flex;
                align-items: center;
                gap: 8px;
                font-size: 0.78rem;
                color: var(--pui-text-secondary);
                font-weight: 500;
            }
            .pui-ticket-stat i {
                color: var(--pui-text-tertiary);
                width: 14px;
                text-align: center;
            }
            .pui-dispatch-form {
                position: sticky;
                top: 0;
            }
            .pui-dispatch-form .pui-card-header {
                background: var(--pui-bg-surface);
            }
            .pui-dispatch-form .pui-card-header h3 i {
                color: var(--pui-accent);
                margin-right: 6px;
            }
            .pui-dispatch-form-col { /* sticky column wrapper */ }

            /* ═══════════════════════════════════════════════════════════════
               AIRSPACE INTEL
               ═══════════════════════════════════════════════════════════════ */

            .pui-intel-stat {
                display: flex;
                flex-direction: column;
                gap: 4px;
            }
            .pui-intel-stat .label {
                font-size: 0.6rem;
                color: var(--pui-text-tertiary);
                font-weight: 700;
                letter-spacing: 0.1em;
                text-transform: uppercase;
            }
            .pui-intel-stat .value {
                font-family: var(--pui-font-mono);
                font-size: 1.25rem;
                color: var(--pui-text-primary);
                font-weight: 700;
                line-height: 1;
            }
            .pui-intel-stat .value-sm {
                font-family: var(--pui-font-mono);
                font-size: 1.05rem;
                color: var(--pui-text-primary);
                font-weight: 700;
                line-height: 1;
            }
            .pui-intel-stats-quad {
                display: grid;
                grid-template-columns: repeat(4, 1fr);
                gap: 12px;
                padding: 14px 0;
                border-top: 1px solid var(--pui-border-light);
                border-bottom: 1px solid var(--pui-border-light);
                margin-bottom: var(--pui-gap-md);
            }
            .pui-intel-stats-tri {
                display: grid;
                grid-template-columns: repeat(3, 1fr);
                gap: 12px;
                padding-bottom: var(--pui-gap-md);
                margin-bottom: var(--pui-gap-md);
                border-bottom: 1px solid var(--pui-border-light);
            }

            .pui-assessment-row {
                display: flex;
                align-items: flex-start;
                gap: 12px;
                padding: 12px;
                background: var(--pui-bg-surface);
                border-radius: 10px;
                margin-bottom: var(--pui-gap-md);
            }
            .pui-assessment-icon { font-size: 1.2rem; flex-shrink: 0; padding-top: 2px; }
            .pui-assessment-text {
                display: flex;
                flex-direction: column;
                gap: 3px;
            }
            .pui-assessment-text strong {
                font-size: 0.8rem;
                color: var(--pui-text-primary);
                font-weight: 700;
            }
            .pui-assessment-text span {
                font-size: 0.78rem;
                color: var(--pui-text-secondary);
                line-height: 1.5;
            }

            .pui-load-bar-block { margin-bottom: var(--pui-gap-md); }
            .pui-load-bar-head {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 6px;
            }
            .pui-load-bar-track {
                width: 100%;
                height: 6px;
                background: var(--pui-bg-surface);
                border-radius: 3px;
                overflow: hidden;
            }
            .pui-load-bar-fill {
                height: 100%;
                border-radius: 3px;
                transition: width 320ms var(--pui-ease-out);
            }

            .pui-section-head {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 8px;
                margin-top: var(--pui-gap-md);
            }

            .pui-intel-heatmap {
                display: flex;
                gap: 3px;
                height: 32px;
                border-radius: 6px;
                overflow: hidden;
                background: var(--pui-bg-surface);
                padding: 3px;
            }
            .pui-intel-heatblock {
                flex: 1;
                border-radius: 4px;
                position: relative;
                cursor: crosshair;
                transition: transform var(--pui-d-fast) var(--pui-ease);
            }
            .pui-intel-heatblock:hover { transform: scaleY(1.1); }
            .pui-heatblock-tooltip {
                position: absolute;
                bottom: 130%;
                left: 50%;
                transform: translateX(-50%);
                background: var(--pui-text-primary);
                color: var(--pui-bg-base);
                padding: 8px 12px;
                border-radius: 8px;
                font-size: 0.7rem;
                line-height: 1.5;
                text-align: center;
                opacity: 0;
                pointer-events: none;
                transition: opacity var(--pui-d-fast) var(--pui-ease);
                white-space: nowrap;
                z-index: 10;
                box-shadow: var(--pui-shadow-pop);
            }
            .pui-intel-heatblock:hover .pui-heatblock-tooltip { opacity: 1; }

            .pui-top-ops {
                display: flex;
                flex-wrap: wrap;
                align-items: center;
                gap: 6px;
                padding-top: var(--pui-gap-md);
                border-top: 1px solid var(--pui-border-light);
            }

            /* ═══════════════════════════════════════════════════════════════
               SETTINGS
               ═══════════════════════════════════════════════════════════════ */

            .pui-settings-grid {
                display: grid;
                grid-template-columns: 1fr 320px;
                gap: var(--pui-gap-lg);
                align-items: start;
            }
            .pui-settings-aside {
                display: flex;
                flex-direction: column;
                gap: var(--pui-gap-md);
            }

            .pui-theme-options {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 8px;
            }
            .pui-theme-options-row {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 10px;
            }
            .pui-theme-option {
                display: flex;
                align-items: center;
                gap: 10px;
                padding: 10px 12px;
                border: 1px solid var(--pui-border);
                border-radius: 10px;
                cursor: pointer;
                transition:
                    border-color var(--pui-d-fast) var(--pui-ease),
                    background-color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-theme-option:hover {
                background: var(--pui-hover);
                border-color: var(--pui-border-strong);
            }
            .pui-theme-option input { accent-color: var(--pui-accent); }
            .pui-theme-option i {
                color: var(--pui-text-tertiary);
                font-size: 0.85rem;
            }
            .pui-theme-option span {
                color: var(--pui-text-primary);
                font-weight: 500;
                font-size: 0.85rem;
            }
            .pui-theme-option:has(input:checked) {
                border-color: var(--pui-accent);
                background: var(--pui-accent-soft);
            }
            .pui-theme-option:has(input:checked) i { color: var(--pui-accent); }

            .pui-plan-box {
                background: var(--pui-bg-surface);
                border: 1px solid var(--pui-border);
                border-radius: var(--pui-radius);
                padding: 16px;
            }
            .pui-plan-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 8px;
            }
            .pui-plan-header h4 {
                margin: 0;
                font-size: 0.95rem;
                font-weight: 700;
                color: var(--pui-text-primary);
            }
            .pui-plan-price {
                font-size: 1.4rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                margin: 0 0 4px 0;
                letter-spacing: -0.02em;
            }
            .pui-plan-renewal {
                font-size: 0.78rem;
                color: var(--pui-text-tertiary);
                margin: 0;
            }
            .pui-billing-actions {
                display: flex;
                flex-direction: column;
                gap: 8px;
                margin-top: var(--pui-gap-md);
            }

            /* ═══════════════════════════════════════════════════════════════
               ACTION LISTS (Support & Legal)
               ═══════════════════════════════════════════════════════════════ */

            .pui-action-list-body {
                padding: 16px;
            }
            .pui-action-list {
                display: flex;
                flex-direction: column;
                gap: 10px;
            }
            .pui-action-link {
                display: flex;
                align-items: center;
                gap: 12px;
                padding: 12px 14px;
                background: var(--pui-bg-surface);
                border: 1px solid var(--pui-border);
                border-radius: 12px;
                text-decoration: none;
                transition:
                    background-color var(--pui-d-fast) var(--pui-ease),
                    border-color var(--pui-d-fast) var(--pui-ease),
                    transform var(--pui-d-fast) var(--pui-ease),
                    box-shadow var(--pui-d-fast) var(--pui-ease);
            }
            .pui-action-link:hover {
                background: var(--pui-bg-card-elev);
                border-color: var(--pui-border-strong);
                transform: translateY(-2px);
                box-shadow: var(--pui-shadow-card);
            }
            .pui-action-icon {
                width: 36px;
                height: 36px;
                border-radius: 10px;
                background: var(--pui-hover);
                color: var(--pui-text-secondary);
                display: grid;
                place-items: center;
                font-size: 0.95rem;
                transition: background-color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-action-link:hover .pui-action-icon {
                background: var(--pui-border-light);
            }
            .pui-action-text {
                flex: 1;
                font-size: 0.88rem;
                font-weight: 600;
                color: var(--pui-text-primary);
            }
            .pui-action-external {
                font-size: 0.75rem;
                color: var(--pui-text-tertiary);
                opacity: 0.6;
                transition: opacity var(--pui-d-fast) var(--pui-ease);
            }
            .pui-action-link:hover .pui-action-external {
                opacity: 1;
            }

            /* ═══════════════════════════════════════════════════════════════
               WATCHLIST
               ═══════════════════════════════════════════════════════════════ */

            .pui-watchlist-add {
                display: flex;
                gap: 12px;
                align-items: center;
            }
            .pui-watchlist-grid {
                display: flex;
                flex-direction: column;
                gap: var(--pui-gap-md);
            }
            .pui-wl-card {
                background: var(--pui-bg-card);
                border: 1px solid var(--pui-border);
                border-radius: var(--pui-radius-lg);
                box-shadow: var(--pui-shadow-card);
                padding: 16px var(--pui-pad-card);
                transition: border-color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-wl-card.live {
                border-color: var(--pui-pos-soft);
                background: linear-gradient(180deg, var(--pui-pos-soft) 0%, var(--pui-bg-card) 65%);
            }
            .pui-wl-card-top {
                display: flex;
                justify-content: space-between;
                align-items: center;
            }
            .pui-wl-identity {
                display: flex;
                align-items: center;
                gap: 12px;
            }
            .pui-wl-dot {
                width: 10px;
                height: 10px;
                border-radius: 50%;
                flex-shrink: 0;
            }
            .pui-wl-dot.live {
                background: var(--pui-pos);
                animation: puiPulseDot 2s ease-in-out infinite;
            }
            .pui-wl-dot.offline {
                background: var(--pui-text-tertiary);
                opacity: 0.5;
            }
            .pui-wl-username {
                font-size: 0.95rem;
                font-weight: 700;
                color: var(--pui-text-primary);
            }
            .pui-wl-status {
                font-size: 0.72rem;
                color: var(--pui-text-secondary);
                font-weight: 600;
                margin-top: 2px;
            }
            .pui-wl-status.live { color: var(--pui-pos); }
            .pui-watchlist-remove-btn {
                width: 32px;
                height: 32px;
                border-radius: 8px;
                background: transparent;
                border: 1px solid var(--pui-border);
                color: var(--pui-text-tertiary);
                cursor: pointer;
                display: grid;
                place-items: center;
                font-size: 0.8rem;
                transition:
                    background-color var(--pui-d-fast) var(--pui-ease),
                    color var(--pui-d-fast) var(--pui-ease),
                    border-color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-watchlist-remove-btn:hover {
                background: var(--pui-neg-soft);
                color: var(--pui-neg);
                border-color: transparent;
            }
            .pui-wl-flight-info {
                margin-top: 14px;
                padding-top: 14px;
                border-top: 1px solid var(--pui-border-light);
            }
            .pui-wl-route {
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 14px;
                margin-bottom: 12px;
            }
            .pui-wl-icao {
                font-family: var(--pui-font-mono);
                font-size: 1.5rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                letter-spacing: -0.01em;
            }
            .pui-wl-plane-icon {
                color: var(--pui-accent);
                font-size: 1rem;
            }
            .pui-wl-telemetry {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 10px;
            }
            .pui-wl-tele-item {
                display: flex;
                flex-direction: column;
                gap: 3px;
                padding: 9px 12px;
                background: var(--pui-bg-surface);
                border-radius: 8px;
            }
            .pui-wl-tele-item .label {
                font-size: 0.6rem;
                font-weight: 700;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: var(--pui-text-tertiary);
            }
            .pui-wl-tele-item .value {
                font-family: var(--pui-font-mono);
                font-size: 0.92rem;
                font-weight: 700;
                color: var(--pui-text-primary);
            }

            /* ═══════════════════════════════════════════════════════════════
               TOGGLE SWITCH
               ═══════════════════════════════════════════════════════════════ */

            .pui-toggle-label {
                display: inline-flex;
                align-items: center;
                gap: 10px;
                cursor: pointer;
                user-select: none;
            }
            .pui-toggle-label input { display: none; }
            .pui-toggle-track {
                position: relative;
                width: 38px;
                height: 22px;
                background: var(--pui-border);
                border-radius: 999px;
                transition: background-color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-toggle-thumb {
                position: absolute;
                top: 2px;
                left: 2px;
                width: 18px;
                height: 18px;
                background: #fff;
                border-radius: 50%;
                box-shadow: 0 1px 3px rgba(0, 0, 0, 0.15);
                transition: transform var(--pui-d-base) var(--pui-ease);
            }
            .pui-toggle-label input:checked + .pui-toggle-track {
                background: var(--pui-accent);
            }
            .pui-toggle-label input:checked + .pui-toggle-track .pui-toggle-thumb {
                transform: translateX(16px);
            }
            .pui-toggle-text {
                font-size: 0.78rem;
                color: var(--pui-text-secondary);
                font-weight: 600;
            }

            /* ═══════════════════════════════════════════════════════════════
               PERSONAL RECORDS
               ═══════════════════════════════════════════════════════════════ */

            .pui-records-grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
                gap: 12px;
            }
            .pui-record {
                padding: 14px 16px;
                border-radius: var(--pui-radius);
                border: 1px solid var(--pui-border);
                background: var(--pui-bg-surface);
            }
            .pui-record[data-tone="indigo"]  { background: rgba(99,102,241,0.06);  border-color: rgba(99,102,241,0.16); }
            .pui-record[data-tone="emerald"] { background: rgba(16,185,129,0.06);  border-color: rgba(16,185,129,0.16); }
            .pui-record[data-tone="amber"]   { background: rgba(245,158,11,0.06);  border-color: rgba(245,158,11,0.18); }
            .pui-record[data-tone="rose"]    { background: rgba(244,63,94,0.06);   border-color: rgba(244,63,94,0.16); }
            .pui-wrapper-layer[data-theme="dark"] .pui-record[data-tone="indigo"]  { background: rgba(129,140,248,0.10); border-color: rgba(129,140,248,0.22); }
            .pui-wrapper-layer[data-theme="dark"] .pui-record[data-tone="emerald"] { background: rgba(52,211,153,0.10);  border-color: rgba(52,211,153,0.22); }
            .pui-wrapper-layer[data-theme="dark"] .pui-record[data-tone="amber"]   { background: rgba(251,191,36,0.10);  border-color: rgba(251,191,36,0.24); }
            .pui-wrapper-layer[data-theme="dark"] .pui-record[data-tone="rose"]    { background: rgba(251,113,133,0.10); border-color: rgba(251,113,133,0.22); }
            .pui-record-head {
                display: flex;
                align-items: center;
                gap: 10px;
                margin-bottom: 10px;
            }
            .pui-record-icon {
                font-size: 0.9rem;
            }
            .pui-record[data-tone="indigo"]  .pui-record-icon { color: #6366f1; }
            .pui-record[data-tone="emerald"] .pui-record-icon { color: #10b981; }
            .pui-record[data-tone="amber"]   .pui-record-icon { color: #f59e0b; }
            .pui-record[data-tone="rose"]    .pui-record-icon { color: #f43f5e; }
            .pui-wrapper-layer[data-theme="dark"] .pui-record[data-tone="indigo"]  .pui-record-icon { color: #818cf8; }
            .pui-wrapper-layer[data-theme="dark"] .pui-record[data-tone="emerald"] .pui-record-icon { color: #34d399; }
            .pui-wrapper-layer[data-theme="dark"] .pui-record[data-tone="amber"]   .pui-record-icon { color: #fbbf24; }
            .pui-wrapper-layer[data-theme="dark"] .pui-record[data-tone="rose"]    .pui-record-icon { color: #fb7185; }
            .pui-record-label {
                font-size: 0.62rem;
                font-weight: 800;
                letter-spacing: 0.1em;
                text-transform: uppercase;
                color: var(--pui-text-tertiary);
            }
            .pui-record-value {
                font-family: var(--pui-font-mono);
                font-size: 1rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                margin-bottom: 3px;
            }
            .pui-record-sub {
                font-size: 0.72rem;
                color: var(--pui-text-secondary);
            }

            /* ═══════════════════════════════════════════════════════════════
               ONBOARDING
               ═══════════════════════════════════════════════════════════════ */

            .pui-onboarding-container {
                display: flex;
                justify-content: center;
                align-items: center;
                width: 100%;
                min-height: 100%;
                padding: 40px 24px;
            }
            .pui-onboarding-card {
                background: var(--pui-bg-card);
                border: 1px solid var(--pui-border);
                border-radius: var(--pui-radius-xl);
                width: 100%;
                max-width: 500px;
                padding: 40px 36px;
                box-shadow: var(--pui-shadow-modal);
            }
            .pui-onboarding-header {
                text-align: center;
                margin-bottom: 32px;
            }
            .pui-onboarding-icon {
                width: 56px;
                height: 56px;
                margin: 0 auto 18px;
                border-radius: 16px;
                background: var(--pui-accent-soft);
                color: var(--pui-accent);
                font-size: 1.5rem;
                display: grid;
                place-items: center;
            }
            .pui-onboarding-header h2 {
                font-size: 1.7rem;
                margin: 0 0 8px 0;
                font-weight: 700;
                color: var(--pui-text-primary);
                letter-spacing: -0.02em;
            }
            .pui-onboarding-header p {
                color: var(--pui-text-secondary);
                margin: 0;
                font-size: 0.92rem;
                line-height: 1.5;
            }

            /* ═══════════════════════════════════════════════════════════════
               SKELETON — soft pulse, not infinite shimmer
               ═══════════════════════════════════════════════════════════════ */

            .pui-skeleton {
                background: var(--pui-border);
                border-radius: 6px;
                animation: puiPulseSoft 1.6s ease-in-out infinite;
            }

            /* ═══════════════════════════════════════════════════════════════
               EMPTY STATES
               ═══════════════════════════════════════════════════════════════ */

            .pui-empty-state {
                text-align: center;
                padding: 56px 20px;
                background: var(--pui-bg-card);
                border: 1px dashed var(--pui-border);
                border-radius: var(--pui-radius-lg);
            }
            .pui-empty-state i {
                font-size: 2.2rem;
                color: var(--pui-text-tertiary);
                opacity: 0.6;
                margin-bottom: 14px;
                display: block;
            }
            .pui-empty-state h4 {
                margin: 0 0 6px 0;
                color: var(--pui-text-primary);
                font-size: 1rem;
                font-weight: 600;
            }
            .pui-empty-state p {
                margin: 0;
                color: var(--pui-text-secondary);
                font-size: 0.84rem;
                line-height: 1.5;
            }

            /* ═══════════════════════════════════════════════════════════════
               TOASTS — no fullscreen blur, just a clean pop
               ═══════════════════════════════════════════════════════════════ */

            .pui-toast-container {
                position: fixed;
                bottom: 24px;
                right: 24px;
                display: flex;
                flex-direction: column-reverse;
                gap: 10px;
                z-index: 10000;
                pointer-events: none;
                max-width: 360px;
            }
            .pui-toast {
                background: var(--pui-bg-card);
                border: 1px solid var(--pui-border);
                color: var(--pui-text-primary);
                padding: 12px 16px;
                border-radius: var(--pui-radius);
                font-size: 0.84rem;
                font-weight: 500;
                line-height: 1.45;
                box-shadow: var(--pui-shadow-pop);
                font-family: var(--pui-font-sans);
                pointer-events: auto;
                cursor: pointer;
                animation: puiToastIn 240ms var(--pui-ease-out);
                transition:
                    opacity 240ms var(--pui-ease),
                    transform 240ms var(--pui-ease);
            }
            .pui-toast-out {
                opacity: 0;
                transform: translateY(8px);
            }
            .pui-toast-info    { border-color: var(--pui-info-soft); }
            .pui-toast-success { background: var(--pui-pos-soft); border-color: var(--pui-pos-soft); color: var(--pui-pos); }
            .pui-toast-error   { background: var(--pui-neg-soft); border-color: var(--pui-neg-soft); color: var(--pui-neg); }
            .pui-toast-warn    { background: var(--pui-warn-soft); border-color: var(--pui-warn-soft); color: var(--pui-warn); }

            /* ═══════════════════════════════════════════════════════════════
               PERSONALIZATION + DRILL-DOWN + TRENDS — added components
               ═══════════════════════════════════════════════════════════════ */

            /* Cover banner on the Dossier tab */
            .pui-cover-banner {
                position: relative;
                width: 100%;
                height: 160px;
                margin-bottom: var(--pui-gap-lg);
                border-radius: var(--pui-radius-lg);
                background-size: cover;
                background-position: center;
                background-repeat: no-repeat;
                overflow: hidden;
                border: 1px solid var(--pui-border);
            }
            .pui-cover-overlay {
                position: absolute;
                inset: 0;
                display: flex;
                flex-direction: column;
                justify-content: flex-end;
                padding: 18px 22px;
                background: linear-gradient(to top, rgba(0,0,0,0.62) 0%, rgba(0,0,0,0.18) 55%, rgba(0,0,0,0) 100%);
                color: #fff;
            }
            .pui-cover-name {
                font-size: 1.4rem;
                font-weight: 700;
                letter-spacing: -0.01em;
                text-shadow: 0 1px 4px rgba(0,0,0,0.4);
            }
            .pui-cover-bio {
                margin-top: 4px;
                font-size: 0.88rem;
                opacity: 0.92;
                text-shadow: 0 1px 3px rgba(0,0,0,0.4);
            }
            .pui-bio-strip {
                display: flex;
                align-items: center;
                gap: 10px;
                padding: 12px 16px;
                margin-bottom: var(--pui-gap-md);
                background: var(--pui-accent-soft);
                border: 1px solid var(--pui-accent-soft);
                border-radius: var(--pui-radius);
                color: var(--pui-text-secondary);
                font-size: 0.92rem;
                font-style: italic;
            }
            .pui-bio-strip i { color: var(--pui-accent); opacity: 0.7; }

            /* Accent picker swatches */
            .pui-accent-grid {
                display: flex;
                flex-wrap: wrap;
                gap: 10px;
                margin-top: 4px;
            }
            .pui-accent-swatch {
                width: 36px;
                height: 36px;
                border-radius: 50%;
                border: 2px solid var(--pui-border);
                cursor: pointer;
                display: flex;
                align-items: center;
                justify-content: center;
                color: #fff;
                font-size: 0.78rem;
                transition: transform var(--pui-d-fast) var(--pui-ease),
                            border-color var(--pui-d-fast) var(--pui-ease),
                            box-shadow var(--pui-d-fast) var(--pui-ease);
                padding: 0;
            }
            .pui-accent-swatch:hover { transform: scale(1.08); }
            .pui-accent-swatch.active {
                border-color: var(--pui-text-primary);
                box-shadow: 0 0 0 2px var(--pui-bg-card), 0 0 0 4px var(--pui-accent-glow);
            }
            .pui-accent-swatch i { text-shadow: 0 1px 2px rgba(0,0,0,0.3); }

            /* Dock chips & drag states */
            .pui-dock-preview {
                display: flex;
                flex-wrap: wrap;
                gap: 6px;
                margin-bottom: 8px;
            }
            .pui-dock-chip {
                padding: 4px 10px;
                background: var(--pui-bg-input);
                border: 1px solid var(--pui-border);
                border-radius: 100px;
                font-size: 0.78rem;
                color: var(--pui-text-secondary);
            }
            .pui-dock-item.dragging {
                opacity: 0.45;
                cursor: grabbing;
            }
            .pui-dock-item.drop-target {
                box-shadow: inset 0 0 0 2px var(--pui-accent);
                background: var(--pui-accent-soft);
            }
            .pui-dock-item { cursor: grab; }

            /* Small ghost button variant */
            .pui-btn-sm {
                padding: 5px 10px !important;
                font-size: 0.78rem !important;
            }

            /* Drillable inline text (ICAOs, callsigns) */
            .pui-drillable {
                cursor: pointer;
                transition: color var(--pui-d-fast) var(--pui-ease);
                position: relative;
            }
            .pui-drillable:hover {
                color: var(--pui-accent);
            }
            .pui-drillable:hover::after {
                content: '';
                position: absolute;
                left: 0; right: 0; bottom: -2px;
                height: 1px;
                background: var(--pui-accent);
                opacity: 0.5;
            }

            /* Stat-card drill targets */
            .pui-stat-card-clickable {
                position: relative;
                cursor: pointer;
                width: 100%;
                text-align: left;
                font: inherit;
                color: inherit;
                background: var(--pui-bg-card);
                border: 1px solid var(--pui-border);
                transition: transform var(--pui-d-fast) var(--pui-ease),
                            box-shadow var(--pui-d-fast) var(--pui-ease),
                            border-color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-stat-card-clickable:hover {
                transform: translateY(-1px);
                box-shadow: 0 4px 12px var(--pui-accent-glow);
                border-color: var(--pui-accent-soft);
            }
            .pui-stat-drill-hint {
                position: absolute;
                top: 50%;
                right: 14px;
                transform: translateY(-50%);
                color: var(--pui-text-tertiary);
                opacity: 0;
                transition: opacity var(--pui-d-fast) var(--pui-ease),
                            color var(--pui-d-fast) var(--pui-ease);
                font-size: 0.85rem;
            }
            .pui-stat-card-clickable:hover .pui-stat-drill-hint {
                opacity: 1;
                color: var(--pui-accent);
            }

            /* Trends card grid */
            .pui-trends-grid {
                display: grid;
                gap: 4px;
            }
            .pui-trend-row {
                display: grid;
                grid-template-columns: 1.6fr 1fr 1fr 1.4fr;
                align-items: center;
                gap: 12px;
                padding: 10px 0;
                border-bottom: 1px solid var(--pui-border-light);
            }
            .pui-trend-row:last-child { border-bottom: none; }
            .pui-trend-label {
                font-size: 0.88rem;
                color: var(--pui-text-secondary);
            }
            .pui-trend-current {
                font-size: 1.05rem;
                font-weight: 600;
                color: var(--pui-text-primary);
            }
            .pui-trend-delta {
                font-size: 0.92rem;
                font-weight: 600;
            }
            .pui-trend-prev {
                font-size: 0.78rem;
                color: var(--pui-text-tertiary);
                text-align: right;
            }
            .pui-trend-up      { color: var(--pui-pos); }
            .pui-trend-down    { color: var(--pui-neg); }
            .pui-trend-neutral { color: var(--pui-text-tertiary); }
            .pui-trend-arrow {
                margin-right: 4px;
                font-size: 0.75rem;
            }

            /* Drill-down modal */
            .pui-drill-box {
                background: var(--pui-bg-card);
                border: 1px solid var(--pui-border);
                border-radius: var(--pui-radius-xl);
                box-shadow: var(--pui-shadow-modal);
                width: 100%;
                max-width: 480px;
                margin: auto;
                overflow: hidden;
            }
            .pui-drill-header {
                display: flex;
                align-items: center;
                justify-content: space-between;
                padding: 18px 22px;
                border-bottom: 1px solid var(--pui-border-light);
            }
            .pui-drill-header h3 {
                margin: 0;
                font-size: 1.05rem;
                font-weight: 600;
                color: var(--pui-text-primary);
            }
            .pui-drill-body {
                padding: 18px 22px;
            }
            .pui-drill-stat-row {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 10px 0;
                border-bottom: 1px solid var(--pui-border-light);
            }
            .pui-drill-stat-row:last-child { border-bottom: none; }
            .pui-drill-stat-row span {
                font-size: 0.88rem;
                color: var(--pui-text-secondary);
            }
            .pui-drill-stat-row strong {
                font-size: 0.98rem;
                color: var(--pui-text-primary);
                font-variant-numeric: tabular-nums;
            }
            .pui-drill-bar-row {
                margin-bottom: 12px;
            }
            .pui-drill-bar-label {
                display: flex;
                justify-content: space-between;
                font-size: 0.84rem;
                margin-bottom: 4px;
            }
            .pui-drill-bar-name { color: var(--pui-text-primary); font-weight: 500; }
            .pui-drill-bar-meta { color: var(--pui-text-tertiary); }
            .pui-drill-bar-track {
                width: 100%;
                height: 6px;
                background: var(--pui-bg-input);
                border-radius: 3px;
                overflow: hidden;
            }
            .pui-drill-bar-fill {
                height: 100%;
                background: var(--pui-accent);
                border-radius: 3px;
                transition: width var(--pui-d-base) var(--pui-ease);
            }
            .pui-drill-note {
                margin: 12px 0 0 0;
                padding: 10px 12px;
                background: var(--pui-info-soft);
                border-radius: var(--pui-radius-sm);
                color: var(--pui-text-secondary);
                font-size: 0.82rem;
                line-height: 1.5;
            }
            .pui-drill-actions {
                display: flex;
                justify-content: flex-end;
                gap: 8px;
                padding: 14px 22px 18px;
                border-top: 1px solid var(--pui-border-light);
            }

            /* ═══════════════════════════════════════════════════════════════
               UTILITY — fade in
               ═══════════════════════════════════════════════════════════════ */

            .pui-fade-in {
                animation: puiFadeIn 320ms var(--pui-ease-out) both;
            }

            /* ═══════════════════════════════════════════════════════════════
               PREMIUM CONFIRMATION MODAL
               ═══════════════════════════════════════════════════════════════ */
            .pui-confirm-box {
                background: var(--pui-bg-card);
                border: 1px solid var(--pui-border);
                border-radius: var(--pui-radius-xl);
                box-shadow: var(--pui-shadow-modal);
                width: 100%;
                max-width: 420px;
                overflow: hidden;
            }
            .pui-confirm-header {
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 16px;
                padding: 32px 24px 16px;
                text-align: center;
            }
            .pui-confirm-icon {
                width: 56px;
                height: 56px;
                background: var(--pui-neg-soft);
                color: var(--pui-neg);
                border-radius: 16px;
                display: grid;
                place-items: center;
                font-size: 1.6rem;
                box-shadow: 0 8px 16px var(--pui-neg-soft);
            }
            .pui-confirm-header h3 {
                margin: 0;
                font-size: 1.35rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                letter-spacing: -0.01em;
            }
            .pui-confirm-body {
                padding: 0 24px 24px;
                text-align: center;
            }
            .pui-confirm-body p {
                margin: 0 0 20px 0;
                font-size: 0.9rem;
                color: var(--pui-text-secondary);
                line-height: 1.5;
            }
            .pui-confirm-flight-plate {
                background: var(--pui-bg-surface);
                border: 1px solid var(--pui-border-light);
                border-radius: 12px;
                padding: 14px;
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 14px;
            }
            .pui-confirm-route {
                font-family: var(--pui-font-mono);
                font-size: 1.05rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                letter-spacing: 0.02em;
            }
            .pui-confirm-actions {
                display: flex;
                gap: 12px;
                padding: 16px 24px 24px;
                background: var(--pui-bg-surface);
                border-top: 1px solid var(--pui-border-light);
            }
            .pui-confirm-actions button {
                flex: 1;
                padding: 12px;
            }
            .pui-btn-danger {
                background: var(--pui-neg);
                color: #fff;
                border: 1px solid transparent;
                border-radius: 10px;
                font-size: 0.86rem;
                font-weight: 600;
                font-family: var(--pui-font-sans);
                cursor: pointer;
                transition: background-color var(--pui-d-fast) var(--pui-ease), transform var(--pui-d-fast) var(--pui-ease);
                box-shadow: 0 2px 6px rgba(0,0,0,0.15);
            }
            .pui-btn-danger:hover {
                background: #c24040; /* Slightly darker shade of var(--pui-neg) */
            }
            .pui-btn-danger:active {
                transform: translateY(1px);
            }

            /* ═══════════════════════════════════════════════════════════════
               RESPONSIVE
               ═══════════════════════════════════════════════════════════════ */

            @media (max-width: 1100px) {
                .pui-dispatch-layout {
                    grid-template-columns: 1fr;
                }
                .pui-dispatch-form {
                    position: static;
                }
                .pui-settings-grid {
                    grid-template-columns: 1fr;
                }
                .pui-home-grid {
                    grid-template-columns: 1fr;
                }
            }

            @media (max-width: 900px) {
                .pui-shell {
                    height: 95vh;
                    border-radius: var(--pui-radius-lg);
                }
                .pui-content {
                    padding: 18px 20px 110px;
                }
                .pui-topstrip {
                    padding: 0 16px;
                    height: 56px;
                }
                .pui-content { inset: 56px 0 0 0; }
                .pui-user-meta { display: none; }
                .pui-user-chip { padding: 4px; }
                .pui-dock-label { display: none; }
                .pui-dock-item { padding: 10px 12px; }
                .pui-live-card {
                    height: 280px;
                    flex: 0 0 100%;
                }
                .pui-live-stats { grid-template-columns: repeat(2, 1fr); }
                .pui-live-stat:nth-child(2) { border-right: none; }
                .pui-live-stat:nth-child(1), .pui-live-stat:nth-child(2) { border-bottom: 1px solid rgba(255,255,255,0.06); }
                .pui-stats-grid { grid-template-columns: 1fr; }
                .pui-intel-stats-quad { grid-template-columns: repeat(2, 1fr); }
                .pui-intel-stats-tri { grid-template-columns: 1fr; }
                .pui-home-greeting { font-size: 1.4rem; }
                .pui-ticket {
                    flex-direction: column;
                }
                .pui-ticket-actions { 
                    opacity: 1; 
                    top: 16px; 
                    right: 16px; 
                }
                .pui-ticket-stub {
                    border-right: none;
                    border-bottom: 1px dashed var(--pui-border);
                    flex-direction: row;
                    justify-content: space-between;
                    align-items: center;
                    padding: 12px 16px;
                }
                .pui-ticket-cs { margin-top: 0; }
                .pui-ticket-aside {
                    border-left: none;
                    border-top: 1px solid var(--pui-border-light);
                    flex-direction: row;
                    justify-content: space-around;
                    padding: 12px 16px;
                }
            }

            @media (prefers-reduced-motion: reduce) {
                .pui-fade-in,
                .pui-toast,
                .pui-skeleton,
                .pui-wl-dot.live {
                    animation: none !important;
                }
                .pui-wrapper-layer,
                .pui-shell {
                    transition: opacity 80ms linear;
                }
            }

            /* ═══════════════════════════════════════════════════════════════
               DOSSIER HERO & ADVANCED ANALYTICS (Premium Redesign)
               ═══════════════════════════════════════════════════════════════ */

            .pui-dossier-hero {
                position: relative;
                width: 100%;
                border-radius: var(--pui-radius-xl);
                border: 1px solid var(--pui-border);
                overflow: hidden;
                box-shadow: var(--pui-shadow-card);
                margin-bottom: var(--pui-gap-lg);
            }
            .pui-dossier-hero-overlay {
                background: linear-gradient(to bottom, rgba(15,12,8,0.7) 0%, rgba(15,12,8,0.95) 100%);
                padding: 32px 32px 0 32px;
                display: flex;
                flex-direction: column;
                justify-content: space-between;
                min-height: 240px;
            }
            .pui-wrapper-layer[data-theme="light"] .pui-dossier-hero-overlay {
                background: linear-gradient(to bottom, rgba(20,17,13,0.5) 0%, rgba(20,17,13,0.85) 100%);
            }
            .pui-dossier-hero-content {
                display: flex;
                justify-content: space-between;
                align-items: flex-start;
                gap: 24px;
                flex: 1;
            }
            .pui-dossier-profile-group {
                display: flex;
                align-items: center;
                gap: 20px;
            }
            .pui-dossier-avatar {
                width: 72px;
                height: 72px;
                border-radius: 20px;
                background: var(--pui-accent);
                color: var(--pui-text-on-accent);
                font-size: 1.8rem;
                font-weight: 700;
                display: grid;
                place-items: center;
                box-shadow: 0 8px 24px var(--pui-accent-glow);
                border: 2px solid rgba(255,255,255,0.1);
            }
            .pui-dossier-identity {
                display: flex;
                flex-direction: column;
                gap: 4px;
            }
            .pui-dossier-name {
                margin: 0;
                font-size: 1.8rem;
                font-weight: 700;
                color: #fff;
                letter-spacing: -0.02em;
                line-height: 1.1;
                text-shadow: 0 2px 8px rgba(0,0,0,0.4);
            }
            .pui-dossier-username {
                font-family: var(--pui-font-mono);
                font-size: 0.9rem;
                color: var(--pui-accent);
                font-weight: 600;
                letter-spacing: 0.04em;
            }
            .pui-dossier-bio {
                margin-top: 6px;
                font-size: 0.9rem;
                color: rgba(255,255,255,0.8);
                font-style: italic;
                max-width: 400px;
                line-height: 1.4;
            }
            
            /* Interactive Grade Badge */
            .pui-dossier-grade-badge {
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                background: rgba(255,255,255,0.05);
                border: 1px solid rgba(255,255,255,0.1);
                backdrop-filter: blur(8px);
                border-radius: 16px;
                padding: 16px 24px;
                position: relative;
            }
            .pui-dossier-grade-badge:hover {
                background: rgba(255,255,255,0.08);
                border-color: var(--pui-accent);
            }
            .pui-grade-label {
                font-size: 0.65rem;
                font-weight: 800;
                letter-spacing: 0.15em;
                color: rgba(255,255,255,0.6);
                text-transform: uppercase;
                margin-bottom: 4px;
            }
            .pui-grade-value {
                font-family: var(--pui-font-mono);
                font-size: 2.8rem;
                font-weight: 700;
                color: #fff;
                line-height: 1;
                text-shadow: 0 4px 16px rgba(0,0,0,0.5);
            }
            .pui-grade-expand {
                position: absolute;
                top: 8px;
                right: 8px;
                font-size: 0.7rem;
                color: rgba(255,255,255,0.3);
                transition: color var(--pui-d-fast) var(--pui-ease);
            }
            .pui-dossier-grade-badge:hover .pui-grade-expand { color: var(--pui-accent); }

            /* Telemetry Strip inside Hero */
            .pui-dossier-telemetry-strip {
                display: flex;
                align-items: center;
                justify-content: space-between;
                background: rgba(0,0,0,0.4);
                border-top: 1px solid rgba(255,255,255,0.08);
                margin: 0 -32px;
                padding: 16px 32px;
            }
            .pui-dossier-tele-item {
                display: flex;
                flex-direction: column;
                align-items: flex-start;
                gap: 4px;
                background: transparent;
                border: none;
                padding: 4px 8px;
                border-radius: 8px;
                text-align: left;
            }
            button.pui-dossier-tele-item { cursor: pointer; }
            button.pui-dossier-tele-item:hover { background: rgba(255,255,255,0.05); }
            .pui-dossier-tele-item .label {
                font-size: 0.7rem;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.08em;
                color: rgba(255,255,255,0.5);
            }
            .pui-dossier-tele-item .value {
                font-family: var(--pui-font-mono);
                font-size: 1.4rem;
                font-weight: 700;
                color: #fff;
                line-height: 1;
            }
            .pui-dossier-tele-divider {
                width: 1px;
                height: 32px;
                background: rgba(255,255,255,0.1);
            }

            /* Analytics Grid */
            .pui-dossier-analytics-grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
                gap: var(--pui-gap-md);
                margin-bottom: var(--pui-gap-lg);
            }
            .pui-analytics-card {
                display: flex;
                flex-direction: column;
            }
            
            /* Safety Profile */
            .pui-safety-body {
                display: flex;
                flex-direction: column;
                gap: 20px;
            }
            .pui-safety-metrics {
                display: flex;
                justify-content: space-between;
                background: var(--pui-bg-surface);
                padding: 14px 16px;
                border-radius: 12px;
                border: 1px solid var(--pui-border-light);
            }
            .pui-safety-stat {
                display: flex;
                flex-direction: column;
                gap: 4px;
            }
            .pui-safety-stat .label {
                font-size: 0.65rem;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.05em;
                color: var(--pui-text-tertiary);
            }
            .pui-safety-stat .value {
                font-family: var(--pui-font-mono);
                font-size: 1.2rem;
                font-weight: 700;
                color: var(--pui-text-primary);
            }
            .pui-safety-index {
                display: flex;
                flex-direction: column;
                gap: 8px;
            }
            .pui-safety-index-label {
                font-size: 0.8rem;
                font-weight: 600;
                color: var(--pui-text-secondary);
            }
            .pui-safety-index-value {
                font-family: var(--pui-font-mono);
                font-size: 1.8rem;
                font-weight: 700;
                line-height: 1;
            }
            .pui-safety-bar-track {
                width: 100%;
                height: 8px;
                background: var(--pui-bg-surface);
                border-radius: 4px;
                overflow: hidden;
                margin-top: 4px;
            }
            .pui-safety-bar-fill {
                height: 100%;
                border-radius: 4px;
                transition: width 1s cubic-bezier(0.16, 1, 0.3, 1);
            }

            /* Fleet Utilization */
            .pui-fleet-body {
                display: flex;
                flex-direction: column;
                gap: 16px;
                justify-content: center;
                flex: 1;
            }
            .pui-fleet-bar-wrapper {
                display: flex;
                flex-direction: column;
                gap: 6px;
            }
            .pui-fleet-bar-label {
                display: flex;
                justify-content: space-between;
                align-items: center;
            }
            .pui-fleet-bar-bg {
                width: 100%;
                height: 6px;
                background: var(--pui-bg-surface);
                border-radius: 3px;
                overflow: hidden;
            }
            .pui-fleet-bar-fill {
                height: 100%;
                border-radius: 3px;
                transition: width 1s cubic-bezier(0.16, 1, 0.3, 1);
            }
        `;

        const style = document.createElement('style');
        style.id = 'pui-dashboard-styles';
        style.textContent = css;
        document.head.appendChild(style);
    }
};