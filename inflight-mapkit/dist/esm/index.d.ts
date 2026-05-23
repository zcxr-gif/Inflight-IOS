import type { PluginListenerHandle } from '@capacitor/core';

export interface LngLat { lat: number; lng: number; }
export interface FrameRect { x: number; y: number; width: number; height: number; }

export interface CreateOptions {
  mapId: string;
  frame: FrameRect;
  center?: LngLat;
  zoom?: number;
  mapType?: string;
}

export interface MarkerSpec {
  id: string;
  coord: LngLat;
  title?: string;
  color?: string;
  rotation?: number;
  glyph?: string;
}

export interface PolylineSpec {
  id: string;
  coords: LngLat[];
  color?: string;
  width?: number;
  dashed?: boolean;
}

export interface PolygonSpec {
  id: string;
  rings: LngLat[][];
  fillColor?: string;
  strokeColor?: string;
  strokeWidth?: number;
}

export interface InflightMapkitPlugin {
  create(options: CreateOptions): Promise<void>;
  destroy(options: { mapId: string }): Promise<void>;
  setFrame(options: { mapId: string; frame: FrameRect }): Promise<void>;
  setCamera(options: { mapId: string; center?: LngLat; zoom?: number; pitch?: number; bearing?: number; animated?: boolean }): Promise<void>;
  fitBounds(options: { mapId: string; sw: LngLat; ne: LngLat; paddingTop?: number; paddingRight?: number; paddingBottom?: number; paddingLeft?: number; animated?: boolean }): Promise<void>;
  setMapType(options: { mapId: string; mapType: string }): Promise<void>;
  setMarkers(options: { mapId: string; layerId: string; markers: MarkerSpec[] }): Promise<void>;
  setPolylines(options: { mapId: string; layerId: string; polylines: PolylineSpec[] }): Promise<void>;
  setPolygons(options: { mapId: string; layerId: string; polygons: PolygonSpec[] }): Promise<void>;
  setVisible(options: { mapId: string; layerId: string; visible: boolean }): Promise<void>;
  addListener(event: 'load' | 'mapTap' | 'annotationTap' | 'regionChange', cb: (data: any) => void): Promise<PluginListenerHandle>;
}

export declare const InflightMapkit: InflightMapkitPlugin;
