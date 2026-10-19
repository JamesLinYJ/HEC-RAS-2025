using System;
using System.Collections;
using System.Collections.Generic;
using Geospatial.Rasters;

namespace Geospatial.Vectors;

public class FeatureSegmentSubsetIterator : IEnumerator<int>, IEnumerator, IDisposable
{
	private FeatureSegmentSubset _featureSegmentSubset;

	private int _currentRange = -1;

	private int _currentFeature = -1;

	public int Current
	{
		get
		{
			try
			{
				return _currentFeature;
			}
			catch (Exception)
			{
				throw new IndexOutOfRangeException();
			}
		}
	}

	object IEnumerator.Current => ((IEnumerator<int>)this).Current;

	public FeatureSegmentSubsetIterator(FeatureSegmentSubset featureSegmentSubset)
	{
		_featureSegmentSubset = featureSegmentSubset;
	}

	public bool MoveNext()
	{
		Range1D range1D = _featureSegmentSubset.Ranges[_currentRange];
		if (_currentFeature == range1D.End)
		{
			if (_currentRange == _featureSegmentSubset.Ranges.Count - 1)
			{
				return false;
			}
			_currentRange++;
			_currentFeature = _featureSegmentSubset.Ranges[_currentRange].Start;
		}
		else
		{
			_currentFeature++;
		}
		return true;
	}

	public void Reset()
	{
		_currentRange = -1;
		_currentFeature = -1;
	}

	public void Dispose()
	{
	}
}
