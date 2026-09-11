/* ============================================================================
 * Etiquetas de juego en castellano. Un único sitio donde se nombran las cosas.
 * ========================================================================== */

export const TERRAIN = {
  water:   'Agua',
  lowland: 'Vega',
  forest:  'Bosque',
  hill:    'Colina',
  ridge:   'Cresta',
  rock:    'Roca',
};

export const ZONING = {
  unzoned:     'Sin calificar',
  residential: 'Residencial',
  commercial:  'Comercial',
  industrial:  'Industrial',
  civic:       'Dotacional',
  mixed:       'Mixto',
  protected:   'Protegido',
};

export const CATEGORY = {
  extraction:    'Extracción',
  energy:        'Energía',
  processing:    'Procesado',
  manufacturing: 'Manufactura',
  residential:   'Residencial',
  commercial:    'Comercial',
  civic:         'Dotacional',
  logistics:     'Logística',
};

export const RESOURCE_CATEGORY = {
  raw:       'Materia prima',
  material:  'Material',
  component: 'Componente',
  good:      'Bien de consumo',
  service:   'Servicio',
  utility:   'Suministro',
};

export const SOCIAL_CLASS = { low: 'Clase baja', mid: 'Clase media', high: 'Clase alta' };

export const BUILDING_STATUS = {
  construction: 'En obra',
  idle:         'Parado',
  producing:    'Produciendo',
  paused:       'Pausado',
  derelict:     'Ruinoso',
};

export const LEDGER_KIND = {
  founding:       'Capital fundacional',
  land_purchase:  'Compra de suelo',
  land_sale:      'Venta de suelo',
  construction:   'Obra',
  upgrade:        'Ampliación',
  upkeep:         'Mantenimiento',
  wages:          'Nóminas',
  market_buy:     'Compra en mercado',
  market_sale:    'Venta en mercado',
  rent:           'Alquileres',
  tax:            'Impuestos',
  grant:          'Subvención',
  penalty:        'Sanción',
  adjustment:     'Ajuste',
};

export const SERVICE = {
  none:      '—',
  health:    'Sanidad',
  education: 'Educación',
  safety:    'Seguridad',
  transport: 'Transporte',
  leisure:   'Ocio',
  utility:   'Suministros',
};
